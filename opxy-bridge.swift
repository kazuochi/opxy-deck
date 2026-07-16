// opxy-bridge — turn OP-XY MIDI (via receivemidi on stdin) into Claude Code keystrokes.
//
// Usage:
//   receivemidi dev "OP-XY" nn | ./opxy-bridge mapping.json [--dry-run] [--tmux <target>]
//
// Injection modes:
//   default   : CGEvent keystrokes to the frontmost app (Terminal CLI or the Claude desktop app).
//               Requires Accessibility permission for the app that runs this (e.g. your terminal).
//   --tmux    : `tmux send-keys -t <target>` — focus-free, no permissions; for CLI-in-tmux
//               setups (including driving a session you're viewing from an iPad over SSH).
//   --dry-run : print decoded actions without sending anything.

import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Config

struct KeyMap: Codable {
    let note: Int
    let action: String
    let label: String?
    let command: String? // for action "shell": the command to run via /bin/sh -c
}

struct KnobMap: Codable {
    let cc: Int
    let mode: String // "relative" | "absolute"
    let action: String
    let label: String?
    let invert: Bool? // flip turn direction if it feels backwards
}

// Momentary CC button (e.g. OP-XY transport keys: record/play/stop send CC 127 on
// press, 0 on release). Behaves like a KeyMap but triggered by control-change.
struct ButtonMap: Codable {
    let cc: Int
    let action: String
    let label: String?
    let command: String? // for action "shell": the command to run via /bin/sh -c
}

struct Mapping: Codable {
    let keys: [KeyMap]
    let knobs: [KnobMap]
    let buttons: [ButtonMap]?   // optional → old mapping files still decode
}

// MARK: - Key codes (macOS virtual keys)

let VK_RETURN: CGKeyCode = 36
let VK_ESCAPE: CGKeyCode = 53
let VK_SPACE: CGKeyCode = 49
let VK_T: CGKeyCode = 17
let VK_LEFT: CGKeyCode = 123
let VK_RIGHT: CGKeyCode = 124
let VK_DOWN: CGKeyCode = 125
let VK_UP: CGKeyCode = 126
let VK_PAGEUP: CGKeyCode = 116
let VK_PAGEDOWN: CGKeyCode = 121

// MARK: - Output backends

protocol Sender {
    func key(_ code: CGKeyCode, flags: CGEventFlags, name: String)
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

    func key(_ code: CGKeyCode, flags: CGEventFlags, name: String) {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log("sent \(name)")
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

    func key(_ code: CGKeyCode, flags: CGEventFlags, name: String) {
        let hasOpt = flags.contains(.maskAlternate)
        switch (code, hasOpt) {
        case (VK_RETURN, _): run(["Enter"])
        case (VK_ESCAPE, _): run(["Escape"])
        case (VK_SPACE, _): run(["Space"])
        case (VK_UP, _): run(["Up"])
        case (VK_DOWN, _): run(["Down"])
        case (VK_LEFT, _): run(["Left"])
        case (VK_RIGHT, _): run(["Right"])
        case (VK_PAGEUP, _): run(["PageUp"])
        case (VK_PAGEDOWN, _): run(["PageDown"])
        case (VK_T, true): run(["M-t"])
        default: break
        }
        log("tmux \(name)")
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
    func key(_ code: CGKeyCode, flags: CGEventFlags, name: String) { log("[dry] \(name)") }
    func text(_ s: String) { log("[dry] type \"\(s)\"") }
    func scroll(_ lines: Int, name: String) { log("[dry] scroll \(lines) (\(name))") }
    func shell(_ command: String) { log("[dry] shell: \(command)") }
}

func log(_ s: String) {
    FileHandle.standardError.write(("opxy-bridge: " + s + "\n").data(using: .utf8)!)
}

// MARK: - Actions

final class Engine {
    let sender: Sender
    let mapping: Mapping
    var pttDownAt: [String: DispatchTime] = [:]   // control id -> press time
    var lastAbs: [Int: Int] = [:]                 // cc -> last absolute value
    let minHoldForRelease = 0.25                  // seconds; shorter = treated as tap (start only)

    init(sender: Sender, mapping: Mapping) {
        self.sender = sender
        self.mapping = mapping
    }

    // Shared action logic — invoked by both note keys and momentary CC buttons.
    // `id` uniquely names the physical control ("note53", "cc55") for hold tracking.
    func press(_ action: String, id: String, command: String? = nil) {
        switch action {
        case "shell":
            guard let cmd = command, !cmd.isEmpty else { log("shell action on \(id) has no \"command\""); return }
            sender.shell(cmd)
        case "ptt":
            pttDownAt[id] = .now()
            sender.key(VK_SPACE, flags: [], name: "Space (dictation start/stop)")
        case "submit":
            sender.key(VK_RETURN, flags: [], name: "Enter")
        case "esc":
            sender.key(VK_ESCAPE, flags: [], name: "Esc")
        case "model_picker":
            sender.text("/model")
            sender.key(VK_RETURN, flags: [], name: "Enter (open model picker)")
        case "effort_command":
            sender.text("/effort")
            sender.key(VK_RETURN, flags: [], name: "Enter (run /effort)")
        case "thinking_toggle":
            sender.key(VK_T, flags: .maskAlternate, name: "Option+T (thinking toggle)")
        default:
            log("unknown action: \(action)")
        }
    }

    func release(_ action: String, id: String) {
        guard action == "ptt", let t0 = pttDownAt.removeValue(forKey: id) else { return }
        let held = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000
        if held >= minHoldForRelease {
            sender.key(VK_SPACE, flags: [], name: "Space (dictation send after \(String(format: "%.1f", held))s hold)")
        }
        // Short tap: recording keeps running; next tap sends. Both hold and tap-tap styles work.
    }

    func noteOn(_ note: Int) {
        guard let key = mapping.keys.first(where: { $0.note == note }) else { return }
        press(key.action, id: "note\(note)", command: key.command)
    }

    func noteOff(_ note: Int) {
        guard let key = mapping.keys.first(where: { $0.note == note }) else { return }
        release(key.action, id: "note\(note)")
    }

    func controlChange(_ cc: Int, _ value: Int) {
        // Momentary CC button (transport keys): 127 = press, 0 = release.
        if let btn = (mapping.buttons ?? []).first(where: { $0.cc == cc }) {
            if value >= 64 { press(btn.action, id: "cc\(cc)", command: btn.command) }
            else { release(btn.action, id: "cc\(cc)") }
            return
        }
        guard let knob = mapping.knobs.first(where: { $0.cc == cc }) else { return }
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
        if knob.invert == true { clicks = -clicks }
        guard clicks != 0 else { return }

        switch knob.action {
        case "scroll":
            // Smooth line scroll of the output. + = clockwise; up shows older content.
            sender.scroll(clicks * 3, name: "scroll")
        case "scroll_page":
            // Coarse scroll: PageUp/PageDown per detent.
            let code: CGKeyCode = clicks > 0 ? VK_PAGEUP : VK_PAGEDOWN
            let name = clicks > 0 ? "PageUp" : "PageDown"
            for _ in 0..<abs(clicks) { sender.key(code, flags: [], name: name) }
        default:
            // Arrow navigation: effort = Left/Right, everything else = Up/Down.
            let (inc, dec): (CGKeyCode, CGKeyCode) = knob.action == "effort" ? (VK_RIGHT, VK_LEFT) : (VK_DOWN, VK_UP)
            let (incName, decName) = knob.action == "effort" ? ("Right", "Left") : ("Down", "Up")
            for _ in 0..<abs(clicks) {
                sender.key(clicks > 0 ? inc : dec, flags: [], name: clicks > 0 ? incName : decName)
            }
        }
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

// MARK: - Learn mode
// Configure the deck by using the deck: press each pad / turn each knob when
// prompted. Reads the same receivemidi stream on stdin, writes mapping.json —
// no manual sniff, no hand-editing JSON.

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

func runLearn(path: String) {
    say("""

    opxy-bridge learn — configure by using the OP-XY itself.
    (Pipe MIDI in:  receivemidi dev "OP-XY" nn | ./opxy-bridge --learn \(path))
    Ctrl+C to abort — nothing is written until every control is captured.

    """)

    var keys: [KeyMap] = []; var usedNotes = Set<Int>()
    for (action, label) in LEARN_KEYS {
        say("▶ press the pad for \(action.uppercased())  —  \(label)\n   … ")
        guard let note = awaitNote(excluding: usedNotes) else { say("\nno input — aborted, nothing written.\n"); exit(1) }
        usedNotes.insert(note); keys.append(KeyMap(note: note, action: action, label: label, command: nil))
        say("captured note \(note)\n\n")
    }

    var knobs: [KnobMap] = []; var usedCCs = Set<Int>()
    for (action, label) in LEARN_KNOBS {
        say("▶ turn the knob for \(action.uppercased())  —  \(label)\n   … ")
        guard let cc = awaitCC(excluding: usedCCs) else { say("\nno input — aborted, nothing written.\n"); exit(1) }
        usedCCs.insert(cc); knobs.append(KnobMap(cc: cc, mode: "absolute", action: action, label: label, invert: nil))
        say("captured CC \(cc) (mode: absolute — the OP-XY controller-mode default; use \"relative\" if you switched the device's encoder mode, \"invert\": true to flip direction)\n\n")
    }

    // Preserve any hand-configured transport buttons (learn only captures keys + knobs).
    let existingButtons = (try? Data(contentsOf: URL(fileURLWithPath: path)))
        .flatMap { try? JSONDecoder().decode(Mapping.self, from: $0) }?.buttons
    if let b = existingButtons, !b.isEmpty { say("(kept \(b.count) existing CC button(s) from \(path))\n") }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(Mapping(keys: keys, knobs: knobs, buttons: existingButtons)) else { say("encode failed.\n"); exit(1) }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        say("✓ wrote \(path) — \(keys.count) keys, \(knobs.count) knobs.\n  Test safely with `make dry`, then `make run`.\n")
    } catch {
        say("write failed: \(error)\n"); exit(1)
    }
}

// MARK: - Main

let args = CommandLine.arguments

if args.contains("--learn") {
    let path = args.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "mapping.json"
    runLearn(path: path)
    exit(0)
}

guard args.count >= 2 else {
    log("usage:")
    log("  run:   receivemidi dev \"OP-XY\" nn | opxy-bridge <mapping.json> [--dry-run] [--tmux <target>]")
    log("  learn: receivemidi dev \"OP-XY\" nn | opxy-bridge --learn [mapping.json]")
    exit(1)
}

let mappingURL = URL(fileURLWithPath: args[1])
guard let data = try? Data(contentsOf: mappingURL),
      let mapping = try? JSONDecoder().decode(Mapping.self, from: data) else {
    log("cannot read/parse mapping file: \(args[1])")
    exit(1)
}

let sender: Sender
if args.contains("--dry-run") {
    sender = DrySender()
} else if let i = args.firstIndex(of: "--tmux"), args.count > i + 1 {
    sender = TmuxSender(target: args[i + 1])
} else {
    if !AXIsProcessTrusted() {
        log("WARNING: Accessibility permission not granted — keystrokes will be silently dropped.")
        log("Fix: System Settings → Privacy & Security → Accessibility → enable your terminal app, then restart it.")
    }
    sender = CGSender()
}

let engine = Engine(sender: sender, mapping: mapping)
log("ready — \(mapping.keys.count) keys, \((mapping.buttons ?? []).count) buttons, \(mapping.knobs.count) knobs mapped. Waiting for MIDI…")
while let line = readLine(strippingNewline: true) {
    guard let ev = parseEvent(line) else { continue }
    switch ev {
    case .noteOn(let n, _): engine.noteOn(n)
    case .noteOff(let n):   engine.noteOff(n)
    case .cc(let c, let v): engine.controlChange(c, v)
    }
}
