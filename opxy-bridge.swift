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
}

struct ProfileJ: Codable {
    let app: String?           // human label of the target app
    let chime: String?         // system sound name played when switching to this profile
    let controls: [String: EntryJ]
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
}

struct RtKnob {
    let control: String
    let action: String
    let mode: String
    let invert: Bool
    let cw: KeyPress?
    let ccw: KeyPress?
}

struct RuntimeMapping {
    var notes: [Int: RtEntry] = [:]
    var buttons: [Int: RtEntry] = [:]
    var knobs: [Int: RtKnob] = [:]
    var app: String?
    var chime: String?
    var counts: String { "\(notes.count) keys, \(buttons.count) buttons, \(knobs.count) knobs" }
}

let KNOB_ACTIONS: Set<String> = ["select", "effort", "scroll", "scroll_page", "turn"]
let BUTTON_ACTIONS: Set<String> = ["ptt", "submit", "esc", "model_picker", "effort_command",
                                   "thinking_toggle", "shell", "type", "key", "profile_cycle"]
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
            let mode = e.mode ?? "absolute"
            if mode != "absolute" && mode != "relative" {
                res.errors.append("\(name): mode must be \"absolute\" or \"relative\", got \"\(mode)\"")
                continue
            }
            var cw: KeyPress? = nil, ccw: KeyPress? = nil
            if e.action == "turn" {
                guard let c1 = e.cw, let c2 = e.ccw else {
                    res.errors.append("\(name): action \"turn\" needs \"cw\" and \"ccw\" key chords")
                    continue
                }
                guard let p1 = parseChord(c1), let p2 = parseChord(c2) else {
                    res.errors.append("\(name): bad chord in cw/ccw (\"\(c1)\" / \"\(c2)\")")
                    continue
                }
                cw = p1; ccw = p2
            }
            rt.knobs[id.num] = RtKnob(control: name, action: e.action, mode: mode,
                                      invert: e.invert ?? false, cw: cw, ccw: ccw)
        } else if BUTTON_ACTIONS.contains(e.action) {
            if name.hasSuffix(".turn") {
                res.warnings.append("\(name): button action \"\(e.action)\" on an encoder turn — every detent will fire it")
            }
            var chords: [KeyPress] = []
            switch e.action {
            case "type":
                guard let t = e.text, !t.isEmpty else {
                    res.errors.append("\(name): action \"type\" needs \"text\"")
                    continue
                }
                _ = t
            case "key":
                let names = e.keys ?? (e.chord.map { [$0] } ?? [])
                guard !names.isEmpty else {
                    res.errors.append("\(name): action \"key\" needs \"chord\" or \"keys\"")
                    continue
                }
                var ok = true
                for n in names {
                    guard let kp = parseChord(n) else {
                        res.errors.append("\(name): unknown key chord \"\(n)\"")
                        ok = false
                        break
                    }
                    chords.append(kp)
                }
                if !ok { continue }
            case "shell":
                guard let c = e.command, !c.isEmpty else {
                    res.errors.append("\(name): action \"shell\" needs \"command\"")
                    continue
                }
            default: break
            }
            let entry = RtEntry(control: name, action: e.action, text: e.text, chords: chords, command: e.command)
            if id.isNote { rt.notes[id.num] = entry } else { rt.buttons[id.num] = entry }
        } else {
            res.errors.append("\(name): unknown action \"\(e.action)\" (knob: \(KNOB_ACTIONS.sorted().joined(separator: "/")); button: \(BUTTON_ACTIONS.sorted().joined(separator: "/")))")
        }
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

    init(sender: Sender, rt: RuntimeMapping, dryRun: Bool) {
        self.sender = sender
        self.rt = rt
        self.dryRun = dryRun
    }

    func swap(_ new: RuntimeMapping) {
        lock.lock()
        rt = new
        lastAbs = [:]      // knobs re-prime on first turn after a profile change
        lock.unlock()
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
            sender.press(KP_SPACE.named("Space (dictation start/stop)"))
        case "submit":
            sender.press(KP_ENTER.named("Enter"))
        case "esc":
            sender.press(KP_ESC.named("Esc"))
        case "type":
            typeText(e.text ?? "")
        case "key":
            for k in e.chords { sender.press(k) }
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
        guard e.action == "ptt", let t0 = pttDownAt.removeValue(forKey: id) else { return }
        let held = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000
        if held >= minHoldForRelease {
            sender.press(KP_SPACE.named("Space (dictation send after \(String(format: "%.1f", held))s hold)"))
        }
        // Short tap: recording keeps running; next tap sends. Both hold and tap-tap styles work.
    }

    func noteOn(_ note: Int) {
        guard let e = current().notes[note] else { return }
        press(e, id: "note\(note)")
    }

    func noteOff(_ note: Int) {
        guard let e = current().notes[note] else { return }
        release(e, id: "note\(note)")
    }

    func controlChange(_ cc: Int, _ value: Int) {
        let m = current()
        // Momentary CC button (transport keys): 127 = press, 0 = release.
        if let e = m.buttons[cc] {
            if value >= 64 { press(e, id: "cc\(cc)") }
            else { release(e, id: "cc\(cc)") }
            return
        }
        guard let knob = m.knobs[cc] else { return }
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
