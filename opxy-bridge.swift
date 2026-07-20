// opxy-bridge — turn OP-XY MIDI (via receivemidi on stdin) into keystrokes for
// the app you're controlling (Claude Code today; any app via profiles).
//
// Usage:
//   run:     receivemidi dev "OP-XY" nn | ./opxy-bridge [profile.json | --profile <name>] [--dry-run] [--tmux <target>]
//            (no args = active profile from deck-state.json, hot-reloaded on change)
//   check:   ./opxy-bridge --check [name-or-path]         validate a profile; exit 1 on errors
//   capture: receivemidi dev "OP-XY" nn | ./opxy-bridge --capture [--timeout <sec>]
//            prints the next-touched control as one JSON line (for agents / MIDI-learn)
//   use:     ./opxy-bridge --use <name>                    switch active profile (writes deck-state.json)
//   list:    ./opxy-bridge --profiles                      list available profiles
//   learn:   receivemidi dev "OP-XY" nn | ./opxy-bridge --learn [path]
//   migrate: ./opxy-bridge --migrate <old-mapping.json> <profiles/name.json>
//
// Profiles (schema v1, see MAPPING-SCHEMA.md):
//   bundled:  <repo>/profiles/<name>.json      (shipped, universally useful)
//   private:  ~/.config/opxy-deck/profiles/    (personal; wins on name collision)
//   active:   ~/.config/opxy-deck/deck-state.json {"active": "<name>"}
//   The run loop watches profile + state files (0.5 s mtime poll — robust across
//   editor atomic saves and file creation, unlike a raw kqueue watch) and swaps
//   mappings live: validate first, keep last-good on failure, chime feedback.
//
// Injection modes:
//   default   : CGEvent keystrokes to the frontmost app (Terminal CLI or a desktop app).
//               Requires Accessibility permission for the app that runs this (e.g. your terminal).
//   --tmux    : `tmux send-keys -t <target>` — focus-free, no permissions; for CLI-in-tmux
//               setups (including driving a session you're viewing from an iPad over SSH).
//   --dry-run : print decoded actions without sending anything (also skips chimes/state writes).

import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Paths

let CONFIG_DIR = ProcessInfo.processInfo.environment["OPXY_CONFIG_DIR"]
    ?? (NSHomeDirectory() + "/.config/opxy-deck")
let LOCAL_PROFILES_DIR = CONFIG_DIR + "/profiles"
let STATE_PATH = CONFIG_DIR + "/deck-state.json"

// The bridge binary lives at the repo root; bundled profiles + census sit beside it.
let EXE_DIR: String = {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().path
}()
let BUNDLED_PROFILES_DIR = EXE_DIR + "/profiles"
let CENSUS_PATH: String = {
    for dir in [EXE_DIR, FileManager.default.currentDirectoryPath, CONFIG_DIR] {
        let p = dir + "/opxy-controls.json"
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return EXE_DIR + "/opxy-controls.json"
}()

func log(_ s: String) {
    FileHandle.standardError.write(("opxy-bridge: " + s + "\n").data(using: .utf8)!)
}

// MARK: - Census (control name ↔ MIDI identity; opxy-controls.json)

struct CensusId: Codable { let isNote: Bool; let num: Int }

func loadCensus() -> [String: CensusId] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: CENSUS_PATH)),
          let c = try? JSONDecoder().decode([String: CensusId].self, from: d) else { return [:] }
    return c
}

func reverseCensus(_ census: [String: CensusId]) -> [String: String] {
    // "(n|c)<num>" → name
    var r: [String: String] = [:]
    for (name, id) in census { r[(id.isNote ? "n" : "c") + String(id.num)] = name }
    return r
}

// MARK: - Profile schema v1 (map keyed by census name; see MAPPING-SCHEMA.md)

struct EntryJ: Codable {
    let action: String
    // primitives payloads
    let text: String?          // action "type": literal text; "\n" = Enter
    let chord: String?         // action "key": single chord, e.g. "M-t", "C-c", "Enter"
    let keys: [String]?        // action "key": chord sequence, e.g. ["Escape","Escape"]
    let cw: String?            // action "turn": chord per clockwise detent
    let ccw: String?           // action "turn": chord per counter-clockwise detent
    let command: String?       // action "shell": command via /bin/sh -c
    // knob options
    let mode: String?          // "absolute" (OP-XY default) | "relative"
    let invert: Bool?
    // raw identity fallback for controls the census doesn't name
    let note: Int?
    let cc: Int?
    let label: String?         // free-form, ignored by the engine
    // hold-to-repeat (actions "key"/"type" only): fire the payload again while held,
    // like a real keyboard key. Delay/rate default to the user's macOS key-repeat prefs.
    var `repeat`: Bool? = nil
    var repeatDelayMs: Int? = nil   // before the first repeat; default = system "delay until repeat"
    var repeatRateMs: Int? = nil    // between repeats;        default = system "key repeat rate"
    // action "ptt" only: "tap" (default) sends Space per press — pairs with `/voice tap`,
    // which only starts on an empty input. "hold" emulates a physically held Space
    // (key-down + auto-repeat + key-up on release) — pairs with `/voice hold`, which has
    // no empty-input rule, so dictation can append to a drafted prompt.
    var style: String? = nil
    // Layers: action "layer_toggle" latches the named layer on/off (with a chime —
    // toggle, not hold: only the transport keys report real holds). While a layer is
    // active, any entry with a matching key in "layers" behaves as that variant:
    //   "enc2.click": { "action": "layer_toggle", "layer": "edit" },
    //   "enc2.turn":  { "action": "effort",
    //                   "layers": { "edit": { "action": "turn", "cw": "C-y", "ccw": "C-w" } } }
    var layer: String? = nil
    var layers: [String: EntryJ]? = nil
    // layer_toggle only: auto-drop the layer this long after its last variant use
    // (chimes on expiry). Bench truth behind the design: only transport keys report
    // holds, so "hold-to-keep-a-mode" is impossible — timeout gives click-twist-done.
    var timeoutMs: Int? = nil
}

// The user's macOS key-repeat feel, read once at startup — deck repeat should be
// indistinguishable from holding the real key. Prefs are in ticks of 15 ms and are
// absent until the user moves the slider; absent = system defaults (375 ms, 90 ms).
let SYS_REPEAT: (delay: Double, rate: Double) = {
    let g = UserDefaults.standard
    let d = (g.object(forKey: "InitialKeyRepeat") as? Double) ?? 25
    let r = (g.object(forKey: "KeyRepeat") as? Double) ?? 6
    return (max(0.05, d * 0.015), max(0.02, r * 0.015))
}()

struct ProfileJ: Codable {
    let app: String?           // human label of the target app
    let chime: String?         // system sound name played when switching to this profile
    let controls: [String: EntryJ]
    // Per-agent routing (optional). For a profile whose panes host different agents
    // (herdr multiplexing Claude Code + Codex), `agents` overrides key/button entries
    // by ACTION NAME when the focused pane's agent label matches:
    //   "agents": { "codex": { "effort_command": {"action":"type","text":"/model\n"} } }
    // Detection default is herdr (`pane current` → .result.pane.agent, ~6 ms socket
    // call); `detect` replaces it with any shell command that prints a bare label.
    // No herdr / no label / no match → the base mapping fires, exactly as before.
    var detect: String? = nil
    var agents: [String: [String: EntryJ]]? = nil
}

// Legacy v0 schema (mapping.json arrays) — still loads; new features need v1.
struct KeyMap: Codable { let note: Int; let action: String; let label: String?; let command: String? }
struct KnobMap: Codable { let cc: Int; let mode: String; let action: String; let label: String?; let invert: Bool? }
struct ButtonMap: Codable { let cc: Int; let action: String; let label: String?; let command: String? }
struct Mapping: Codable { let keys: [KeyMap]; let knobs: [KnobMap]; let buttons: [ButtonMap]? }

// MARK: - Key chords (generic keystroke vocabulary)

let VK_RETURN: CGKeyCode = 36
let VK_ESCAPE: CGKeyCode = 53
let VK_SPACE: CGKeyCode = 49
let VK_LEFT: CGKeyCode = 123
let VK_RIGHT: CGKeyCode = 124
let VK_DOWN: CGKeyCode = 125
let VK_UP: CGKeyCode = 126
let VK_PAGEUP: CGKeyCode = 116
let VK_PAGEDOWN: CGKeyCode = 121

struct KeyPress {
    let code: CGKeyCode
    let flags: CGEventFlags
    let tmux: String          // tmux send-keys token; "" = unsupported over tmux (e.g. Cmd-…)
    let name: String          // for logs
    func named(_ n: String) -> KeyPress { KeyPress(code: code, flags: flags, tmux: tmux, name: n) }
}

// name → (virtual keycode, tmux token)
let NAMED_KEYS: [String: (CGKeyCode, String)] = [
    "enter": (36, "Enter"), "return": (36, "Enter"),
    "esc": (53, "Escape"), "escape": (53, "Escape"),
    "space": (49, "Space"), "tab": (48, "Tab"),
    "backspace": (51, "BSpace"), "delete": (117, "DC"),
    "up": (126, "Up"), "down": (125, "Down"), "left": (123, "Left"), "right": (124, "Right"),
    "pageup": (116, "PPage"), "pagedown": (121, "NPage"),
    "home": (115, "Home"), "end": (119, "End"),
    "minus": (27, "-"), "equals": (24, "="),
    "f1": (122, "F1"), "f2": (120, "F2"), "f3": (99, "F3"), "f4": (118, "F4"),
    "f5": (96, "F5"), "f6": (97, "F6"), "f7": (98, "F7"), "f8": (100, "F8"),
    "f9": (101, "F9"), "f10": (109, "F10"), "f11": (103, "F11"), "f12": (111, "F12"),
]
// ANSI-layout single characters (kVK_ANSI_*)
let CHAR_VK: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
]

// "M-t", "C-M-x", "Enter", "S-Left", "Cmd-k" → KeyPress. Modifiers: M/Alt/Opt, C/Ctrl, S/Shift, Cmd/D.
func parseChord(_ s: String) -> KeyPress? {
    if s.isEmpty { return nil }
    var tokens = s == "-" ? ["-"] : s.components(separatedBy: "-")
    if tokens.count > 1 && tokens.last == "" { return nil }
    let base = tokens.removeLast()
    var flags: CGEventFlags = []
    var tmuxMods = ""
    var tmuxOK = true
    for m in tokens {
        switch m.lowercased() {
        case "m", "a", "alt", "opt", "option": flags.insert(.maskAlternate); tmuxMods += "M-"
        case "c", "ctrl", "control": flags.insert(.maskControl); tmuxMods += "C-"
        case "s", "shift": flags.insert(.maskShift); tmuxMods += "S-"
        case "d", "cmd", "command": flags.insert(.maskCommand); tmuxOK = false
        default: return nil
        }
    }
    let lower = base.lowercased()
    if let (code, tok) = NAMED_KEYS[lower] {
        return KeyPress(code: code, flags: flags, tmux: tmuxOK ? tmuxMods + tok : "", name: s)
    }
    if base.count == 1, let code = CHAR_VK[Character(lower)] {
        return KeyPress(code: code, flags: flags, tmux: tmuxOK ? tmuxMods + lower : "", name: s)
    }
    return nil
}

let KP_ENTER = parseChord("Enter")!
let KP_ESC = parseChord("Escape")!
let KP_SPACE = parseChord("Space")!
let KP_UP = parseChord("Up")!
let KP_DOWN = parseChord("Down")!
let KP_LEFT = parseChord("Left")!
let KP_RIGHT = parseChord("Right")!
let KP_PAGEUP = parseChord("PageUp")!
let KP_PAGEDOWN = parseChord("PageDown")!

// MARK: - Output backends

protocol Sender {
    func press(_ k: KeyPress)
    func keyDown(_ k: KeyPress)   // half of a sustained hold — must be paired with keyUp
    func keyUp(_ k: KeyPress)
    func keyRepeat(_ k: KeyPress) // auto-repeat between keyDown and keyUp — MUST carry the
                                  // HID autorepeat flag: an unflagged down reads as a NEW
                                  // press (Claude's hold mode stops recording on it)
    func text(_ s: String)
    func scroll(_ lines: Int, name: String)   // + = up (older), - = down (newer)
    func shell(_ command: String)             // fire-and-forget /bin/sh -c
}

// Default shell runner shared by the real senders; DrySender overrides to print only.
func runShell(_ command: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        DispatchQueue.global().async { p.waitUntilExit() }  // reap without blocking MIDI loop
        log("shell: \(command)")
    } catch {
        log("shell FAILED (\(error.localizedDescription)): \(command)")
    }
}

final class CGSender: Sender {
    private let src = CGEventSource(stateID: .hidSystemState)

    func press(_ k: KeyPress) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: false) else { return }
        down.flags = k.flags
        up.flags = k.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log("sent \(k.name)")
    }

    func keyDown(_ k: KeyPress) {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: true) else { return }
        ev.flags = k.flags
        ev.post(tap: .cghidEventTap)
        log("sent \(k.name)")
    }

    func keyUp(_ k: KeyPress) {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: false) else { return }
        ev.flags = k.flags
        ev.post(tap: .cghidEventTap)
        log("sent \(k.name)")
    }

    func keyRepeat(_ k: KeyPress) {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: true) else { return }
        ev.flags = k.flags
        ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        ev.post(tap: .cghidEventTap)
        // no log — repeats fire at key-repeat rate and would flood the console
    }

    func scroll(_ lines: Int, name: String) {
        // Synthesize a mouse-wheel scroll (line units). Routed to the window under
        // the cursor, so keep the pointer over the terminal while scrolling.
        if let ev = CGEvent(scrollWheelEvent2Source: src, units: .line,
                            wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0) {
            ev.post(tap: .cghidEventTap)
        }
        log("scroll \(lines) (\(name))")
    }

    func shell(_ command: String) { runShell(command) }

    func text(_ s: String) {
        for scalar in s.unicodeScalars {
            let chars = [UniChar(scalar.value)]
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                chars.withUnsafeBufferPointer { buf in
                    down.keyboardSetUnicodeString(stringLength: 1, unicodeString: buf.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: 1, unicodeString: buf.baseAddress)
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(2000)
            }
        }
        log("typed \"\(s)\"")
    }
}

final class TmuxSender: Sender {
    let target: String
    init(target: String) { self.target = target }

    private func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux", "send-keys", "-t", target] + args
        try? p.run()
        p.waitUntilExit()
    }

    func press(_ k: KeyPress) {
        guard !k.tmux.isEmpty else { log("tmux: \(k.name) not sendable over tmux — skipped"); return }
        run([k.tmux])
        log("tmux \(k.name)")
    }

    // send-keys has no key-up/down halves, but hold-mode dictation doesn't need them:
    // Claude keeps recording alive from the repeat CHAR stream and treats its silence
    // as the release (verified live via pty injection). So a hold over tmux = the same
    // char at the hold cadence until release.
    func keyDown(_ k: KeyPress) {
        guard !k.tmux.isEmpty else { log("tmux: \(k.name) not sendable — skipped"); return }
        run([k.tmux])
        log("tmux hold start (char-stream): \(k.name)")
    }

    func keyUp(_ k: KeyPress) {}       // release = the stream stopping
    func keyRepeat(_ k: KeyPress) {
        guard !k.tmux.isEmpty else { return }
        run([k.tmux])                  // no log — fires at hold cadence
    }

    func text(_ s: String) {
        run(["-l", s])
        log("tmux typed \"\(s)\"")
    }

    func scroll(_ lines: Int, name: String) {
        // No wheel injection over tmux; drive copy-mode scrollback (pane must be in copy-mode).
        run(["-X", "-N", String(abs(lines)), lines > 0 ? "scroll-up" : "scroll-down"])
        log("tmux scroll \(lines) (\(name))")
    }

    func shell(_ command: String) { runShell(command) }
}

final class DrySender: Sender {
    func press(_ k: KeyPress) { log("[dry] \(k.name)") }
    func keyDown(_ k: KeyPress) { log("[dry] \(k.name)") }
    func keyUp(_ k: KeyPress) { log("[dry] \(k.name)") }
    func keyRepeat(_ k: KeyPress) { log("[dry] \(k.name)") }
    func text(_ s: String) { log("[dry] type \"\(s)\"") }
    func scroll(_ lines: Int, name: String) { log("[dry] scroll \(lines) (\(name))") }
    func shell(_ command: String) { log("[dry] shell: \(command)") }
}

// MARK: - Runtime mapping (schema-independent decode tables)

struct RtEntry {
    let control: String        // census name or "note53"/"cc55"
    let action: String
    let text: String?
    let chords: [KeyPress]
    let command: String?
    var repeatSpec: (delay: Double, rate: Double)? = nil   // resolved seconds; nil = no repeat
    var pttHold: Bool = false                              // ptt style "hold": Space held for the press duration
    var layerName: String? = nil                           // action "layer_toggle": which layer
    var layerTimeout: Double? = nil                        // seconds of variant inactivity → auto-off
    var layerVariants: [String: RtEntry] = [:]             // layer name → replacement while active
}

struct RtKnob {
    let control: String
    let action: String
    let mode: String
    let invert: Bool
    let cw: KeyPress?
    let ccw: KeyPress?
    var layerVariants: [String: RtKnob] = [:]   // layer name → replacement while active
}

struct RuntimeMapping {
    var notes: [Int: RtEntry] = [:]
    var buttons: [Int: RtEntry] = [:]
    var detect: String? = nil                                // custom agent-label command
    var agentOverrides: [String: [String: RtEntry]] = [:]    // label → action name → entry
    var knobs: [Int: RtKnob] = [:]
    var app: String?
    var chime: String?
    var counts: String { "\(notes.count) keys, \(buttons.count) buttons, \(knobs.count) knobs" }
}

let KNOB_ACTIONS: Set<String> = ["select", "effort", "scroll", "scroll_page", "turn"]
let BUTTON_ACTIONS: Set<String> = ["ptt", "submit", "esc", "model_picker", "effort_command",
                                   "thinking_toggle", "shell", "type", "key", "profile_cycle", "nop",
                                   "layer_toggle"]
// Transport core — invariant verbs across profiles (muscle-memory guard; warning only)
let CORE_VERBS: [String: String] = ["transport.record": "ptt", "transport.play": "submit", "transport.stop": "esc"]

struct LoadResult {
    var runtime: RuntimeMapping?
    var errors: [String] = []
    var warnings: [String] = []
}

func loadRuntime(path: String, census: [String: CensusId]) -> LoadResult {
    var res = LoadResult()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        res.errors.append("cannot read \(path)")
        return res
    }
    if let v1 = try? JSONDecoder().decode(ProfileJ.self, from: data) {
        return buildRuntime(v1, census: census)
    }
    if let v0 = try? JSONDecoder().decode(Mapping.self, from: data) {
        return buildRuntime(legacyToProfile(v0, census: census), census: census)
    }
    res.errors.append("cannot parse \(path) as profile (v1) or legacy mapping (v0)")
    return res
}

// Validate a knob entry and build its runtime form. Shared by the controls loop and
// per-layer knob variants (variants inherit the base knob's mode/invert unless set).
func buildKnobEntry(_ name: String, _ e: EntryJ, _ res: inout LoadResult,
                    defaultMode: String = "absolute", defaultInvert: Bool = false) -> RtKnob? {
    let mode = e.mode ?? defaultMode
    if mode != "absolute" && mode != "relative" {
        res.errors.append("\(name): mode must be \"absolute\" or \"relative\", got \"\(mode)\"")
        return nil
    }
    var cw: KeyPress? = nil, ccw: KeyPress? = nil
    if e.action == "turn" {
        guard let c1 = e.cw, let c2 = e.ccw else {
            res.errors.append("\(name): action \"turn\" needs \"cw\" and \"ccw\" key chords")
            return nil
        }
        guard let p1 = parseChord(c1), let p2 = parseChord(c2) else {
            res.errors.append("\(name): bad chord in cw/ccw (\"\(c1)\" / \"\(c2)\")")
            return nil
        }
        cw = p1; ccw = p2
    }
    return RtKnob(control: name, action: e.action, mode: mode,
                  invert: e.invert ?? defaultInvert, cw: cw, ccw: ccw)
}

// Validate a key/button entry's payload and build its runtime form. Shared by the
// controls loop and the agents override tables; `name` labels error messages
// (a control name, or "agents.<label>.<verb>").
func buildButtonEntry(_ name: String, _ e: EntryJ, _ res: inout LoadResult) -> RtEntry? {
    if let s = e.style, e.action != "ptt" {
        res.warnings.append("\(name): \"style\" only applies to action \"ptt\" — ignored on \"\(e.action)\" (got \"\(s)\")")
    }
    var chords: [KeyPress] = []
    switch e.action {
    case "ptt":
        if let s = e.style, s != "tap" && s != "hold" {
            res.errors.append("\(name): ptt style must be \"tap\" or \"hold\", got \"\(s)\"")
            return nil
        }
    case "type":
        guard let t = e.text, !t.isEmpty else {
            res.errors.append("\(name): action \"type\" needs \"text\"")
            return nil
        }
        _ = t
    case "key":
        let names = e.keys ?? (e.chord.map { [$0] } ?? [])
        guard !names.isEmpty else {
            res.errors.append("\(name): action \"key\" needs \"chord\" or \"keys\"")
            return nil
        }
        for n in names {
            guard let kp = parseChord(n) else {
                res.errors.append("\(name): unknown key chord \"\(n)\"")
                return nil
            }
            chords.append(kp)
        }
    case "shell":
        guard let c = e.command, !c.isEmpty else {
            res.errors.append("\(name): action \"shell\" needs \"command\"")
            return nil
        }
    case "layer_toggle":
        guard let l = e.layer, !l.isEmpty else {
            res.errors.append("\(name): action \"layer_toggle\" needs \"layer\" (the layer name)")
            return nil
        }
    default: break
    }
    var rep: (delay: Double, rate: Double)? = nil
    if e.`repeat` == true {
        if e.action == "key" || e.action == "type" {
            rep = (e.repeatDelayMs.map { max(0.05, Double($0) / 1000) } ?? SYS_REPEAT.delay,
                   e.repeatRateMs.map  { max(0.02, Double($0) / 1000) } ?? SYS_REPEAT.rate)
        } else {
            res.warnings.append("\(name): \"repeat\" only applies to actions \"key\"/\"type\" — ignored on \"\(e.action)\"")
        }
    }
    if e.timeoutMs != nil && e.action != "layer_toggle" {
        res.warnings.append("\(name): \"timeoutMs\" only applies to action \"layer_toggle\" — ignored")
    }
    var entry = RtEntry(control: name, action: e.action, text: e.text, chords: chords,
                        command: e.command, repeatSpec: rep,
                        pttHold: e.action == "ptt" && e.style == "hold",
                        layerName: e.layer,
                        layerTimeout: e.action == "layer_toggle" ? e.timeoutMs.map { max(0.2, Double($0) / 1000) } : nil)
    // Per-layer variants (depth 1: a variant cannot itself carry layers or toggle one).
    for (lname, v) in (e.layers ?? [:]).sorted(by: { $0.key < $1.key }) {
        let ctx = "\(name).layers.\(lname)"
        guard BUTTON_ACTIONS.contains(v.action), v.action != "layer_toggle" else {
            res.errors.append("\(ctx): layer variant needs a key/button action (not layer_toggle)")
            continue
        }
        var flat = v; flat.layers = nil
        if let ve = buildButtonEntry(ctx, flat, &res) { entry.layerVariants[lname] = ve }
    }
    return entry
}

func buildRuntime(_ p: ProfileJ, census: [String: CensusId]) -> LoadResult {
    var res = LoadResult()
    var rt = RuntimeMapping()
    rt.app = p.app
    rt.chime = p.chime
    var seen: [String: String] = [:]  // "(n|c)num" → control name (duplicate detection)

    for (name, e) in p.controls.sorted(by: { $0.key < $1.key }) {
        // resolve MIDI identity: explicit raw fields win, else census name
        let id: CensusId
        if let n = e.note { id = CensusId(isNote: true, num: n) }
        else if let c = e.cc { id = CensusId(isNote: false, num: c) }
        else if let c = census[name] { id = c }
        else {
            res.errors.append("\(name): unknown control (not in census \(CENSUS_PATH); add \"note\" or \"cc\")")
            continue
        }
        let idKey = (id.isNote ? "n" : "c") + String(id.num)
        if let prev = seen[idKey] {
            res.errors.append("\(name): same MIDI control as \(prev) (\(id.isNote ? "note" : "CC") \(id.num))")
            continue
        }
        seen[idKey] = name

        if let want = CORE_VERBS[name], e.action != want {
            res.warnings.append("\(name): core verb overridden (\(want) → \(e.action)) — transport core is meant to stay invariant across profiles")
        }

        if KNOB_ACTIONS.contains(e.action) {
            if id.isNote {
                res.errors.append("\(name): knob action \"\(e.action)\" on a note-sending control")
                continue
            }
            if name.hasSuffix(".click") || name.hasPrefix("transport.") {
                res.warnings.append("\(name): knob action \"\(e.action)\" on a momentary button — turns won't happen")
            }
            guard var knob = buildKnobEntry(name, e, &res) else { continue }
            for (lname, v) in (e.layers ?? [:]).sorted(by: { $0.key < $1.key }) {
                let ctx = "\(name).layers.\(lname)"
                guard KNOB_ACTIONS.contains(v.action) else {
                    res.errors.append("\(ctx): layer variant of a knob needs a knob action (\(KNOB_ACTIONS.sorted().joined(separator: "/")))")
                    continue
                }
                if let vk = buildKnobEntry(ctx, v, &res, defaultMode: knob.mode, defaultInvert: knob.invert) {
                    knob.layerVariants[lname] = vk
                }
            }
            rt.knobs[id.num] = knob
        } else if BUTTON_ACTIONS.contains(e.action) {
            if name.hasSuffix(".turn") {
                res.warnings.append("\(name): button action \"\(e.action)\" on an encoder turn — every detent will fire it")
            }
            guard let entry = buildButtonEntry(name, e, &res) else { continue }
            if id.isNote { rt.notes[id.num] = entry } else { rt.buttons[id.num] = entry }
        } else {
            res.errors.append("\(name): unknown action \"\(e.action)\" (knob: \(KNOB_ACTIONS.sorted().joined(separator: "/")); button: \(BUTTON_ACTIONS.sorted().joined(separator: "/")))")
        }
    }

    // Per-agent overrides: label → semantic action name → replacement entry.
    rt.detect = p.detect
    for (label, verbs) in (p.agents ?? [:]).sorted(by: { $0.key < $1.key }) {
        var table: [String: RtEntry] = [:]
        for (verb, e) in verbs.sorted(by: { $0.key < $1.key }) {
            let ctx = "agents.\(label).\(verb)"
            guard BUTTON_ACTIONS.contains(verb) else {
                res.errors.append("\(ctx): overrides route by key/button action name (\(BUTTON_ACTIONS.sorted().joined(separator: "/")))")
                continue
            }
            guard BUTTON_ACTIONS.contains(e.action) else {
                res.errors.append("\(ctx): unknown action \"\(e.action)\"")
                continue
            }
            guard let entry = buildButtonEntry(ctx, e, &res) else { continue }
            table[verb] = entry
        }
        if !table.isEmpty { rt.agentOverrides[label] = table }
    }
    if p.detect != nil && rt.agentOverrides.isEmpty {
        res.warnings.append("\"detect\" set but no \"agents\" overrides — detection will never be used")
    }

    res.runtime = res.errors.isEmpty ? rt : nil
    return res
}

// v0 arrays → v1 entries (census names where known; raw note/cc keys otherwise)
func legacyToProfile(_ m: Mapping, census: [String: CensusId]) -> ProfileJ {
    let rev = reverseCensus(census)
    var controls: [String: EntryJ] = [:]
    func name(isNote: Bool, num: Int) -> (String, Int?, Int?) {
        if let n = rev[(isNote ? "n" : "c") + String(num)] { return (n, nil, nil) }
        return (isNote ? "note\(num)" : "cc\(num)", isNote ? num : nil, isNote ? nil : num)
    }
    for k in m.keys {
        let (n, note, cc) = name(isNote: true, num: k.note)
        controls[n] = EntryJ(action: k.action, text: nil, chord: nil, keys: nil, cw: nil, ccw: nil,
                             command: k.command, mode: nil, invert: nil, note: note, cc: cc, label: k.label)
    }
    for b in m.buttons ?? [] {
        let (n, note, cc) = name(isNote: false, num: b.cc)
        controls[n] = EntryJ(action: b.action, text: nil, chord: nil, keys: nil, cw: nil, ccw: nil,
                             command: b.command, mode: nil, invert: nil, note: note, cc: cc, label: b.label)
    }
    for k in m.knobs {
        let (n, note, cc) = name(isNote: false, num: k.cc)
        controls[n] = EntryJ(action: k.action, text: nil, chord: nil, keys: nil, cw: nil, ccw: nil,
                             command: nil, mode: k.mode, invert: k.invert, note: note, cc: cc, label: k.label)
    }
    return ProfileJ(app: nil, chime: nil, controls: controls)
}

// MARK: - Profiles & state

struct StateJ: Codable { var active: String? }

func readActiveName() -> String {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: STATE_PATH)),
          let s = try? JSONDecoder().decode(StateJ.self, from: d),
          let a = s.active, !a.isEmpty else { return "claude-code" }
    return a
}

func writeState(active: String) {
    try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? (try? enc.encode(StateJ(active: active)))?.write(to: URL(fileURLWithPath: STATE_PATH))
}

// name → path; private (~/.config) wins over bundled (repo)
func resolveProfilePath(_ name: String) -> String? {
    for dir in [LOCAL_PROFILES_DIR, BUNDLED_PROFILES_DIR] {
        let p = dir + "/" + name + ".json"
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}

func availableProfiles() -> [String] {
    var names = Set<String>()
    for dir in [LOCAL_PROFILES_DIR, BUNDLED_PROFILES_DIR] {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        where f.hasSuffix(".json") {
            names.insert(String(f.dropLast(5)))
        }
    }
    return names.sorted()
}

let SWITCH_SOUNDS = ["Glass", "Ping", "Pop", "Purr", "Tink", "Funk", "Hero", "Morse"]

func chime(_ name: String?, index: Int) {
    let sound: String
    if let n = name, !n.isEmpty, n.allSatisfy({ $0.isLetter }) { sound = n }
    else { sound = SWITCH_SOUNDS[abs(index) % SWITCH_SOUNDS.count] }
    runShell("afplay /System/Library/Sounds/\(sound).aiff")
}

func chimeError() { runShell("afplay /System/Library/Sounds/Sosumi.aiff") }

// MARK: - Engine

final class Engine {
    let sender: Sender
    let dryRun: Bool
    private var rt: RuntimeMapping
    private let lock = NSLock()
    var pttDownAt: [String: DispatchTime] = [:]   // control id -> press time
    var lastAbs: [Int: Int] = [:]                 // cc -> last absolute value
    let minHoldForRelease = 0.25                  // seconds; shorter = treated as tap (start only)

    // Keyboard-style auto-repeat. Guarded by `lock`: press/release run on the stdin
    // thread, swap() on the reloader's timer thread.
    private var repeatTimers: [String: DispatchSourceTimer] = [:]
    private let repeatQ = DispatchQueue(label: "opxy.repeat")
    // Safety cap, the one deliberate difference from a real keyboard: a real key never
    // loses its release, a BLE key can. Without release for this long → stop; re-press
    // to continue. A runaway repeater aimed at Backspace would otherwise eat the prompt.
    let maxRepeatWindow = 5.0

    // PTT "hold" style. Claude's hold-mode contract (verified against the 2.1.215 binary
    // AND live on a pane): recording starts on Space, stays alive from the *auto-repeat
    // stream*, and "no repeats within the warmup (~200 ms) → fallback release timer →
    // stop". Key release events are NOT consulted — the stream's silence IS the release.
    // So a hold = key-down + repeats at a fixed fast cadence (liveness signal, deliberately
    // NOT the user's cosmetic key-repeat prefs — a 375 ms first repeat misses the warmup
    // and recording dies ~0.5 s in), + key-up for hygiene.
    // Guarded by `lock` like repeatTimers. Cap sits above Claude's 2-min recording limit:
    // a BLE-lost release would otherwise leave the stream running forever.
    private var holdTimers: [String: DispatchSourceTimer] = [:]
    let holdCadence = 0.05        // must beat the warmup window; real repeats run 30–90 ms
    let maxHoldWindow = 150.0

    init(sender: Sender, rt: RuntimeMapping, dryRun: Bool) {
        self.sender = sender
        self.rt = rt
        self.dryRun = dryRun
    }

    func swap(_ new: RuntimeMapping) {
        lock.lock()
        rt = new
        lastAbs = [:]      // knobs re-prime on first turn after a profile change
        repeatTimers.values.forEach { $0.cancel() }   // a held key must not repeat across a profile switch
        repeatTimers = [:]
        let held = holdTimers
        holdTimers = [:]
        activeLayers = []   // a latched layer must not survive a profile switch
        layerTimers.values.forEach { $0.cancel() }
        layerTimers = [:]
        lock.unlock()
        held.values.forEach { $0.cancel() }           // a held Space must not survive a profile switch either
        if !held.isEmpty { sender.keyUp(KP_SPACE.named("Space up (dictation hold — profile switch)")) }
    }

    // Fire the entry's payload again after `delay`, then every `rate`, until release
    // cancels it. The cap is armed as a separate delayed cancel of this specific timer
    // instance, so a re-press (new timer) is never killed by the old press's cap.
    private func startRepeat(_ e: RtEntry, id: String) {
        guard let spec = e.repeatSpec else { return }
        let t = DispatchSource.makeTimerSource(queue: repeatQ)
        t.schedule(deadline: .now() + spec.delay, repeating: spec.rate)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            switch e.action {
            case "key":  for k in e.chords { self.sender.press(k) }
            case "type": self.typeText(e.text ?? "")
            default: break
            }
        }
        repeatQ.asyncAfter(deadline: .now() + maxRepeatWindow) { [control = e.control] in
            if !t.isCancelled { t.cancel(); log("repeat: \(control) capped at 5 s without release — re-press to continue") }
        }
        t.resume()
        lock.lock()
        repeatTimers.removeValue(forKey: id)?.cancel()
        repeatTimers[id] = t
        lock.unlock()
    }

    private func cancelRepeat(_ id: String) {
        lock.lock()
        let t = repeatTimers.removeValue(forKey: id)
        lock.unlock()
        t?.cancel()
    }

    private func startHold(_ id: String) {
        let t = DispatchSource.makeTimerSource(queue: repeatQ)
        t.schedule(deadline: .now() + holdCadence, repeating: holdCadence)
        t.setEventHandler { [weak self] in
            self?.sender.keyRepeat(KP_SPACE.named("Space repeat (dictation hold)"))
        }
        // Cap targets this timer instance, so a release+re-press is never killed by the
        // old press's cap (same pattern as the repeat cap above).
        repeatQ.asyncAfter(deadline: .now() + maxHoldWindow) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.holdTimers[id] === t
            if live { self.holdTimers.removeValue(forKey: id) }
            self.lock.unlock()
            guard live else { return }
            t.cancel()
            self.sender.keyUp(KP_SPACE.named("Space up (dictation hold cap)"))
            log("ptt hold: \(id) capped at \(Int(self.maxHoldWindow)) s without a MIDI release")
        }
        t.resume()
        lock.lock()
        holdTimers.removeValue(forKey: id)?.cancel()
        holdTimers[id] = t
        lock.unlock()
    }

    // Release an active hold's Space, exactly once. False if none live (already capped/swapped).
    @discardableResult
    private func endHold(_ id: String) -> Bool {
        lock.lock()
        let t = holdTimers.removeValue(forKey: id)
        lock.unlock()
        guard let t else { return false }
        t.cancel()
        sender.keyUp(KP_SPACE.named("Space up (dictation release)"))
        return true
    }

    private func current() -> RuntimeMapping {
        lock.lock(); defer { lock.unlock() }
        return rt
    }

    // Shared action logic — invoked by both note keys and momentary CC buttons.
    func press(_ e: RtEntry, id: String) {
        switch e.action {
        case "shell":
            sender.shell(e.command ?? "")
        case "ptt":
            pttDownAt[id] = .now()
            if e.pttHold {
                sender.keyDown(KP_SPACE.named("Space down (dictation hold)"))
                startHold(id)
            } else {
                sender.press(KP_SPACE.named("Space (dictation start/stop)"))
            }
        case "submit":
            sender.press(KP_ENTER.named("Enter"))
        case "esc":
            sender.press(KP_ESC.named("Esc"))
        case "type":
            typeText(e.text ?? "")
            startRepeat(e, id: id)
        case "key":
            for k in e.chords { sender.press(k) }
            startRepeat(e, id: id)
        case "model_picker":
            sender.text("/model")
            sender.press(KP_ENTER.named("Enter (open model picker)"))
        case "effort_command":
            sender.text("/effort")
            sender.press(KP_ENTER.named("Enter (run /effort)"))
        case "thinking_toggle":
            sender.press(parseChord("M-t")!.named("Option+T (thinking toggle)"))
        case "profile_cycle":
            cycleProfile()
        case "nop":
            log("nop (\(e.control))")
        case "layer_toggle":
            guard let name = e.layerName else { return }
            lock.lock()
            let on = !activeLayers.contains(name)
            if on {
                activeLayers.insert(name)
                if let t = e.layerTimeout { layerTimeouts[name] = t } else { layerTimeouts.removeValue(forKey: name) }
            } else {
                activeLayers.remove(name)
                layerTimers.removeValue(forKey: name)?.cancel()
            }
            lock.unlock()
            log("layer \(name): \(on ? "ON" : "off") (\(e.control))")
            // Audible mode indicator — the deck has no screen; Tink = in, Bottle = out.
            if !dryRun { runShell("afplay /System/Library/Sounds/\(on ? "Tink" : "Bottle").aiff") }
            if on { armLayerExpiry(name) }
        default:
            log("unknown action: \(e.action)")
        }
    }

    // "\n" in text = Enter (typing a literal newline is unreliable across terminals/apps)
    private func typeText(_ s: String) {
        let parts = s.components(separatedBy: "\n")
        for (i, seg) in parts.enumerated() {
            if !seg.isEmpty { sender.text(seg) }
            if i < parts.count - 1 { sender.press(KP_ENTER.named("Enter")) }
        }
    }

    private func cycleProfile() {
        let names = availableProfiles()
        guard !names.isEmpty else { log("profile_cycle: no profiles found"); return }
        let cur = readActiveName()
        let idx = names.firstIndex(of: cur) ?? -1
        let next = names[(idx + 1) % names.count]
        if dryRun {
            log("[dry] profile_cycle → \(next)")
        } else {
            writeState(active: next)   // the reloader picks this up and swaps + chimes
            log("profile_cycle → \(next)")
        }
    }

    func release(_ e: RtEntry, id: String) {
        cancelRepeat(id)
        guard e.action == "ptt", let t0 = pttDownAt.removeValue(forKey: id) else { return }
        if e.pttHold { endHold(id); return }
        let held = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000
        if held >= minHoldForRelease {
            sender.press(KP_SPACE.named("Space (dictation send after \(String(format: "%.1f", held))s hold)"))
        }
        // Short tap: recording keeps running; next tap sends. Both hold and tap-tap styles work.
    }

    // MARK: Per-agent routing
    //
    // A press resolves against the focused pane's agent label and the resolution is
    // pinned until release — so a ptt release always pairs with the entry its press
    // used, even if pane focus moves mid-hold. Touched only on the stdin thread
    // (like pttDownAt).
    private var routedPress: [String: RtEntry] = [:]

    // Latched layers (layer_toggle). Guarded by `lock`: events arrive on the stdin
    // thread, auto-expiry fires on repeatQ. A layer with timeoutMs drops itself that
    // long after its last variant use — click, twist, stop; no closing click needed.
    private var activeLayers: Set<String> = []
    private var layerTimers: [String: DispatchSourceTimer] = [:]
    private var layerTimeouts: [String: Double] = [:]

    private func armLayerExpiry(_ name: String) {
        lock.lock()
        let timeout = layerTimeouts[name]
        lock.unlock()
        guard let timeout else { return }
        let t = DispatchSource.makeTimerSource(queue: repeatQ)
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.layerTimers[name] === t && self.activeLayers.contains(name)
            if live { self.activeLayers.remove(name); self.layerTimers.removeValue(forKey: name)?.cancel() }
            self.lock.unlock()
            guard live else { return }
            log("layer \(name): off (timeout)")
            if !self.dryRun { runShell("afplay /System/Library/Sounds/Bottle.aiff") }
        }
        t.resume()
        lock.lock()
        layerTimers.removeValue(forKey: name)?.cancel()
        layerTimers[name] = t
        lock.unlock()
    }

    // A layer variant wins outright — an explicit user mode beats agent routing.
    // Using a variant refreshes its layer's inactivity timer.
    private func applyLayers(_ e: RtEntry) -> (RtEntry, Bool) {
        lock.lock(); let layers = activeLayers.sorted(); lock.unlock()
        for l in layers { if let v = e.layerVariants[l] { armLayerExpiry(l); return (v, true) } }
        return (e, false)
    }
    private func applyLayers(_ k: RtKnob) -> RtKnob {
        lock.lock(); let layers = activeLayers.sorted(); lock.unlock()
        for l in layers { if let v = k.layerVariants[l] { armLayerExpiry(l); return v } }
        return k
    }

    // Focused-pane agent label. Built-in: herdr `pane current` (~6 ms socket call);
    // PATH is extended because a Finder-launched .app doesn't see /opt/homebrew/bin.
    // A profile's "detect" replaces it with any command printing a bare label.
    // 150 ms guard so a wedged detector degrades to the base mapping, not a stuck key.
    private func detectAgent(_ m: RuntimeMapping) -> String? {
        let builtin = m.detect == nil
        let cmd = m.detect ?? "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" herdr pane current"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + 0.15) == .timedOut { p.terminate(); return nil }
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { return nil }
        if !builtin { return out }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let pane = result["pane"] as? [String: Any],
              let agent = pane["agent"] as? String, !agent.isEmpty else { return nil }
        return agent
    }

    private func route(_ e: RtEntry, _ m: RuntimeMapping) -> RtEntry {
        guard !m.agentOverrides.isEmpty else { return e }   // zero cost for single-agent profiles
        guard let label = detectAgent(m), let o = m.agentOverrides[label]?[e.action] else { return e }
        log("route: \(label) → \(e.action) ⇒ \(o.action)")
        return o
    }

    func noteOn(_ note: Int) {
        let m = current()
        guard let base = m.notes[note] else { return }
        let (le, layered) = applyLayers(base)
        let e = layered ? le : route(le, m)
        routedPress["note\(note)"] = e
        press(e, id: "note\(note)")
    }

    func noteOff(_ note: Int) {
        guard let base = current().notes[note] else { return }
        release(routedPress.removeValue(forKey: "note\(note)") ?? base, id: "note\(note)")
    }

    func controlChange(_ cc: Int, _ value: Int) {
        let m = current()
        // Momentary CC button (transport keys): 127 = press, 0 = release.
        if let base = m.buttons[cc] {
            if value >= 64 {
                let (le, layered) = applyLayers(base)
                let e = layered ? le : route(le, m)
                routedPress["cc\(cc)"] = e
                press(e, id: "cc\(cc)")
            } else {
                release(routedPress.removeValue(forKey: "cc\(cc)") ?? base, id: "cc\(cc)")
            }
            return
        }
        guard let rawKnob = m.knobs[cc] else { return }
        let knob = applyLayers(rawKnob)
        var clicks = 0
        if knob.mode == "relative" {
            // Two's-complement style: 1..63 = clockwise, 65..127 = counter-clockwise.
            if value >= 1 && value <= 63 { clicks = min(value, 3) }
            else if value >= 65 && value <= 127 { clicks = -min(128 - value, 3) }
        } else {
            // Absolute 0..127 (OP-XY controller-mode default): clicks = position delta.
            let prev = lastAbs[cc] ?? value   // first event primes, no output
            lastAbs[cc] = value
            var d = value - prev
            if d == 0 {
                // Pegged at a rail: device re-sends the bound on further turning.
                if value == 0 { d = -1 } else if value == 127 { d = 1 }
            }
            clicks = max(-3, min(3, d))
        }
        if knob.invert { clicks = -clicks }
        guard clicks != 0 else { return }

        switch knob.action {
        case "scroll":
            // Smooth line scroll of the output. + = clockwise; up shows older content.
            sender.scroll(clicks * 3, name: knob.control)
        case "scroll_page":
            // Coarse scroll: PageUp/PageDown per detent.
            let k = clicks > 0 ? KP_PAGEUP : KP_PAGEDOWN
            for _ in 0..<abs(clicks) { sender.press(k) }
        case "turn":
            // Generic knob: arbitrary chord per detent, each direction.
            guard let k = clicks > 0 ? knob.cw : knob.ccw else { return }
            for _ in 0..<abs(clicks) { sender.press(k) }
        default:
            // Arrow navigation: effort = Left/Right, everything else = Up/Down.
            let k = knob.action == "effort" ? (clicks > 0 ? KP_RIGHT : KP_LEFT)
                                            : (clicks > 0 ? KP_DOWN : KP_UP)
            for _ in 0..<abs(clicks) { sender.press(k) }
        }
    }
}

// MARK: - Hot reload (0.5 s mtime poll on state + active profile)

final class Reloader {
    private let census: [String: CensusId]
    private let dry: Bool
    private let explicitPath: String?      // set = pinned profile (no state watching)
    private let onSwap: (RuntimeMapping) -> Void
    private(set) var name: String
    private(set) var path: String
    private var profMtime: Date?
    private var stateMtime: Date?
    private var timer: DispatchSourceTimer?

    init(census: [String: CensusId], dry: Bool, explicitPath: String?,
         name: String, path: String, onSwap: @escaping (RuntimeMapping) -> Void) {
        self.census = census
        self.dry = dry
        self.explicitPath = explicitPath
        self.name = name
        self.path = path
        self.onSwap = onSwap
        self.profMtime = mtime(path)
        self.stateMtime = mtime(STATE_PATH)
    }

    private func mtime(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "opxy.reload"))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        // 1. active-profile switch via deck-state.json (only when not pinned to a path)
        if explicitPath == nil {
            let sm = mtime(STATE_PATH)
            if sm != stateMtime {
                stateMtime = sm
                let newName = readActiveName()
                if newName != name { switchTo(newName) }
            }
        }
        // 2. active profile file edited in place
        let pm = mtime(path)
        if pm != profMtime {
            profMtime = pm
            reload(reason: "edited")
        }
    }

    private func switchTo(_ newName: String) {
        guard let newPath = resolveProfilePath(newName) else {
            log("switch FAILED: no profile named \"\(newName)\" (available: \(availableProfiles().joined(separator: ", "))) — staying on \(name)")
            if !dry { chimeError() }
            return
        }
        let res = loadRuntime(path: newPath, census: census)
        for w in res.warnings { log("warning: \(w)") }
        guard let rt = res.runtime else {
            for e in res.errors { log("error: \(e)") }
            log("switch FAILED: \(newName) is invalid — staying on \(name)")
            if !dry { chimeError() }
            return
        }
        name = newName
        path = newPath
        profMtime = mtime(newPath)
        onSwap(rt)
        log("profile: \(newName) (\(newPath)) — \(rt.counts)")
        if !dry { chime(rt.chime, index: availableProfiles().firstIndex(of: newName) ?? 0) }
    }

    private func reload(reason: String) {
        let res = loadRuntime(path: path, census: census)
        for w in res.warnings { log("warning: \(w)") }
        guard let rt = res.runtime else {
            for e in res.errors { log("error: \(e)") }
            log("reload FAILED (\(reason)) — keeping last-good \(name)")
            if !dry { chimeError() }
            return
        }
        onSwap(rt)
        log("reloaded \(name) (\(reason)) — \(rt.counts)")
    }
}

// MARK: - receivemidi line parser
// Expected lines (receivemidi ... nn):
//   channel  1   note-on          48 100
//   channel  1   note-off         48  64
//   channel  1   control-change    1  65

enum MidiEvent {
    case noteOn(Int, Int)   // note, velocity
    case noteOff(Int)       // note
    case cc(Int, Int)       // controller, value
}

func parseEvent(_ line: String) -> MidiEvent? {
    let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard let ti = tokens.firstIndex(where: { ["note-on", "note-off", "control-change"].contains($0) }) else { return nil }
    guard tokens.count > ti + 2, let a = Int(tokens[ti + 1]), let b = Int(tokens[ti + 2]) else { return nil }
    switch tokens[ti] {
    case "note-on":        return b > 0 ? .noteOn(a, b) : .noteOff(a)  // some devices send note-on vel 0 as note-off
    case "note-off":       return .noteOff(a)
    case "control-change": return .cc(a, b)
    default:               return nil
    }
}

// MARK: - Verbs: check / capture / use / profiles / migrate

// name-or-path → concrete path ("" = active profile)
func resolveCheckTarget(_ arg: String?) -> String? {
    if let a = arg, !a.isEmpty {
        if a.contains("/") || a.hasSuffix(".json") {
            return FileManager.default.fileExists(atPath: a) ? a : nil
        }
        return resolveProfilePath(a)
    }
    return resolveProfilePath(readActiveName())
}

func runCheck(_ arg: String?) -> Never {
    guard let path = resolveCheckTarget(arg) else {
        log("check: cannot resolve \"\(arg ?? readActiveName())\" (available: \(availableProfiles().joined(separator: ", ")))")
        exit(1)
    }
    print("check: \(path)")
    let res = loadRuntime(path: path, census: loadCensus())
    for e in res.errors { print("error: \(e)") }
    for w in res.warnings { print("warning: \(w)") }
    if let rt = res.runtime {
        let warn = res.warnings.isEmpty ? "" : ", \(res.warnings.count) warning(s)"
        print("OK — \(rt.counts)\(warn)")
        exit(0)
    }
    print("FAILED — \(res.errors.count) error(s)")
    exit(1)
}

func runCapture(timeout: Double) -> Never {
    let census = loadCensus()
    let rev = reverseCensus(census)
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        log("capture: timeout after \(Int(timeout))s — no control touched")
        exit(1)
    }
    log("capture: touch a control on the OP-XY…")
    while let line = readLine(strippingNewline: true) {
        guard let ev = parseEvent(line) else { continue }
        let isNote: Bool, num: Int, value: Int
        switch ev {
        case .noteOn(let n, let v): isNote = true; num = n; value = v
        case .cc(let c, let v) where v > 0: isNote = false; num = c; value = v
        default: continue   // ignore releases so a lingering note-off can't be captured
        }
        let name = rev[(isNote ? "n" : "c") + String(num)]
        let control = name.map { "\"\($0)\"" } ?? "null"
        print("{\"control\":\(control),\"isNote\":\(isNote),\"num\":\(num),\"value\":\(value)}")
        exit(0)
    }
    log("capture: input ended — no control touched")
    exit(1)
}

func runUse(_ name: String) -> Never {
    guard resolveProfilePath(name) != nil else {
        log("use: no profile named \"\(name)\" (available: \(availableProfiles().joined(separator: ", ")))")
        exit(1)
    }
    writeState(active: name)
    print("active: \(name)")
    exit(0)
}

func runProfilesList() -> Never {
    let active = readActiveName()
    let names = availableProfiles()
    if names.isEmpty { print("no profiles found (\(LOCAL_PROFILES_DIR), \(BUNDLED_PROFILES_DIR))") }
    for n in names {
        let local = FileManager.default.fileExists(atPath: LOCAL_PROFILES_DIR + "/" + n + ".json")
        print("\(n == active ? "*" : " ") \(n)  (\(local ? "private" : "bundled"))")
    }
    exit(0)
}

func runMigrate(_ old: String, _ out: String) -> Never {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: old)),
          let m = try? JSONDecoder().decode(Mapping.self, from: d) else {
        log("migrate: cannot read/parse legacy mapping \(old)")
        exit(1)
    }
    let census = loadCensus()
    var p = legacyToProfile(m, census: census)
    p = ProfileJ(app: "Claude Code", chime: "Glass", controls: p.controls)
    let res = buildRuntime(p, census: census)
    for w in res.warnings { log("warning: \(w)") }
    guard res.errors.isEmpty else {
        for e in res.errors { log("error: \(e)") }
        exit(1)
    }
    try? FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: out).deletingLastPathComponent().path,
        withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(p), (try? data.write(to: URL(fileURLWithPath: out))) != nil else {
        log("migrate: write failed: \(out)")
        exit(1)
    }
    print("migrated \(old) → \(out) (\(res.runtime!.counts))")
    exit(0)
}

// MARK: - Learn mode
// Configure the deck by using the deck: press each pad / turn each knob when
// prompted. Reads the same receivemidi stream on stdin, writes the active
// profile (v1 schema) — no manual sniff, no hand-editing JSON.

let LEARN_KEYS: [(String, String)] = [
    ("ptt",             "dictate — hold to listen, release to send (also tap-to-start / tap-to-send)"),
    ("submit",          "Enter — submit / accept selection"),
    ("esc",             "Esc — interrupt; press twice on empty input = rewind menu"),
    ("model_picker",    "types /model + Enter, then knobs navigate"),
    ("thinking_toggle", "Option+T — toggle extended thinking"),
]
let LEARN_KNOBS: [(String, String)] = [
    ("select", "Up/Down — model list, rewind selection, permission options, history"),
    ("effort", "Left/Right — thinking effort in the model picker, dialog tabs"),
]

func say(_ s: String) { FileHandle.standardError.write(s.data(using: .utf8)!) }

func drainUntilNoteOff(_ note: Int) {
    // Consume the release (and any hold-repeats) so the next prompt starts clean.
    while let line = readLine(strippingNewline: true) {
        if case .noteOff(let n)? = parseEvent(line), n == note { return }
    }
}

func awaitNote(excluding used: Set<Int>) -> Int? {
    while let line = readLine(strippingNewline: true) {
        guard case .noteOn(let n, _)? = parseEvent(line) else { continue }
        if used.contains(n) { say("  (note \(n) already used — press a different pad) "); continue }
        drainUntilNoteOff(n)
        return n
    }
    return nil
}

func awaitCC(excluding used: Set<Int>) -> Int? {
    while let line = readLine(strippingNewline: true) {
        guard case .cc(let c, _)? = parseEvent(line) else { continue }
        if used.contains(c) { say("  (CC \(c) already used — turn a different knob) "); continue }
        return c
    }
    return nil
}

func runLearn(path explicit: String?) {
    let census = loadCensus()
    let rev = reverseCensus(census)
    let activeName = readActiveName()
    let path = explicit
        ?? resolveProfilePath(activeName)
        ?? BUNDLED_PROFILES_DIR + "/" + activeName + ".json"

    say("""

    opxy-bridge learn — configure by using the OP-XY itself.
    Writes: \(path)
    (Pipe MIDI in:  receivemidi dev "OP-XY" nn | ./opxy-bridge --learn)
    Ctrl+C to abort — nothing is written until every control is captured.

    """)

    func entryName(isNote: Bool, num: Int) -> (String, Int?, Int?) {
        if let n = rev[(isNote ? "n" : "c") + String(num)] { return (n, nil, nil) }
        return (isNote ? "note\(num)" : "cc\(num)", isNote ? num : nil, isNote ? nil : num)
    }

    var learned: [String: EntryJ] = [:]
    var usedNotes = Set<Int>()
    for (action, label) in LEARN_KEYS {
        say("▶ press the pad for \(action.uppercased())  —  \(label)\n   … ")
        guard let note = awaitNote(excluding: usedNotes) else { say("\nno input — aborted, nothing written.\n"); exit(1) }
        usedNotes.insert(note)
        let (n, rawNote, rawCC) = entryName(isNote: true, num: note)
        learned[n] = EntryJ(action: action, text: nil, chord: nil, keys: nil, cw: nil, ccw: nil,
                            command: nil, mode: nil, invert: nil, note: rawNote, cc: rawCC, label: label)
        say("captured \(n) (note \(note))\n\n")
    }

    var usedCCs = Set<Int>()
    for (action, label) in LEARN_KNOBS {
        say("▶ turn the knob for \(action.uppercased())  —  \(label)\n   … ")
        guard let cc = awaitCC(excluding: usedCCs) else { say("\nno input — aborted, nothing written.\n"); exit(1) }
        usedCCs.insert(cc)
        let (n, rawNote, rawCC) = entryName(isNote: false, num: cc)
        learned[n] = EntryJ(action: action, text: nil, chord: nil, keys: nil, cw: nil, ccw: nil,
                            command: nil, mode: "absolute", invert: nil, note: rawNote, cc: rawCC, label: label)
        say("captured \(n) (CC \(cc), mode: absolute — the OP-XY controller-mode default; use \"relative\" if you switched the device's encoder mode, \"invert\": true to flip direction)\n\n")
    }

    // Preserve everything this learn pass didn't capture (transport buttons, macros, …).
    var existing: [String: EntryJ] = [:]
    var app: String? = nil, chimeName: String? = nil
    if let d = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        if let p = try? JSONDecoder().decode(ProfileJ.self, from: d) {
            existing = p.controls; app = p.app; chimeName = p.chime
        } else if let m = try? JSONDecoder().decode(Mapping.self, from: d) {
            existing = legacyToProfile(m, census: census).controls
        }
    }
    let learnedActions = Set(LEARN_KEYS.map { $0.0 } + LEARN_KNOBS.map { $0.0 })
    var controls = existing.filter { !learnedActions.contains($0.value.action) }
    if controls.count != existing.count || !existing.isEmpty {
        say("(kept \(controls.count) existing entr\(controls.count == 1 ? "y" : "ies") from \(path))\n")
    }
    controls.merge(learned) { _, new in new }

    try? FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
        withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(ProfileJ(app: app, chime: chimeName, controls: controls)) else {
        say("encode failed.\n"); exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        say("✓ wrote \(path) — \(controls.count) controls.\n  Test safely with `make dry`, then `make run`.\n")
    } catch {
        say("write failed: \(error)\n"); exit(1)
    }
}

// MARK: - Main

let args = CommandLine.arguments

func flagValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
    return args[i + 1]
}

if args.contains("--learn") {
    runLearn(path: args.dropFirst().first(where: { !$0.hasPrefix("--") }))
    exit(0)
}
if args.contains("--check") {
    let target = flagValue("--check").flatMap { $0.hasPrefix("--") ? nil : $0 }
    runCheck(target)
}
if args.contains("--capture") {
    runCapture(timeout: flagValue("--timeout").flatMap(Double.init) ?? 15)
}
if args.contains("--use") {
    guard let n = flagValue("--use") else { log("use: profile name required"); exit(1) }
    runUse(n)
}
if args.contains("--profiles") {
    runProfilesList()
}
if args.contains("--ax") {
    // Accessibility status of the invoking terminal (doctor uses this)
    let ok = AXIsProcessTrusted()
    print(ok ? "granted" : "missing")
    exit(ok ? 0 : 1)
}
if args.contains("--migrate") {
    guard let i = args.firstIndex(of: "--migrate"), args.count > i + 2 else {
        log("migrate: usage: opxy-bridge --migrate <old-mapping.json> <profiles/name.json>")
        exit(1)
    }
    runMigrate(args[i + 1], args[i + 2])
}

// Run mode. Profile source, in order: positional path > --profile <name> > deck-state.json.
let dryRun = args.contains("--dry-run")
let positional = args.dropFirst().first(where: { !$0.hasPrefix("--") && $0 != flagValue("--tmux") && $0 != flagValue("--profile") })
let census = loadCensus()
if census.isEmpty { log("WARNING: census not found (\(CENSUS_PATH)) — only raw note/cc entries will resolve.") }

let startName: String
let startPath: String
let pinnedPath: String?
if let p = positional {
    startName = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
    startPath = p
    pinnedPath = p
} else if let n = flagValue("--profile") {
    guard let p = resolveProfilePath(n) else {
        log("no profile named \"\(n)\" (available: \(availableProfiles().joined(separator: ", ")))")
        exit(1)
    }
    startName = n
    startPath = p
    pinnedPath = p   // pinned by name: state changes don't switch it, edits still hot-reload
} else {
    let n = readActiveName()
    guard let p = resolveProfilePath(n) else {
        log("active profile \"\(n)\" not found (available: \(availableProfiles().joined(separator: ", ")))")
        log("fix: ./opxy-bridge --use <name>, or add \(BUNDLED_PROFILES_DIR)/\(n).json")
        exit(1)
    }
    startName = n
    startPath = p
    pinnedPath = nil
}

let initial = loadRuntime(path: startPath, census: census)
for w in initial.warnings { log("warning: \(w)") }
guard let rt0 = initial.runtime else {
    for e in initial.errors { log("error: \(e)") }
    log("cannot load profile \(startPath)")
    exit(1)
}

let sender: Sender
if dryRun {
    sender = DrySender()
} else if let t = flagValue("--tmux") {
    sender = TmuxSender(target: t)
} else {
    if !AXIsProcessTrusted() {
        log("WARNING: Accessibility permission not granted — keystrokes will be silently dropped.")
        log("Fix: System Settings → Privacy & Security → Accessibility → enable your terminal app, then restart it.")
    }
    sender = CGSender()
}

let engine = Engine(sender: sender, rt: rt0, dryRun: dryRun)
let reloader = Reloader(census: census, dry: dryRun, explicitPath: pinnedPath,
                        name: startName, path: startPath, onSwap: { engine.swap($0) })
reloader.start()

log("profile: \(startName) (\(startPath)) — \(rt0.counts). Hot-reload on. Waiting for MIDI…")
while let line = readLine(strippingNewline: true) {
    guard let ev = parseEvent(line) else { continue }
    switch ev {
    case .noteOn(let n, _): engine.noteOn(n)
    case .noteOff(let n):   engine.noteOff(n)
    case .cc(let c, let v): engine.controlChange(c, v)
    }
}
