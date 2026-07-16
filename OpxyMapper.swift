// OpxyMapper v2 — GUI key mapper for the OP-XY Claude Deck.
//
// Full-panel line-art rendition of the OP-XY: every physical control is clickable.
// Click a control → (if unknown) press it on the device to identify → assign an
// action → Save. Runs/stops the bridge from the toolbar, shows OP-XY connection.
// Writes the same mapping.json the bridge reads; identities live in
// opxy-controls.json. Self-drawn schematic (not TE artwork).
//
// Build & run: make gui

import SwiftUI
import CoreMIDI
import CoreBluetooth
import CoreAudioKit

// MARK: - Bridge-compatible mapping schema (keep in sync with opxy-bridge.swift)

struct KeyMapJ: Codable {
    let note: Int; let action: String; let label: String?; let command: String?
}
struct KnobMapJ: Codable {
    let cc: Int; let mode: String; let action: String; let label: String?; let invert: Bool?
}
struct ButtonMapJ: Codable {
    let cc: Int; let action: String; let label: String?; let command: String?
}
struct MappingJ: Codable {
    var keys: [KeyMapJ]; var knobs: [KnobMapJ]; var buttons: [ButtonMapJ]?
}

// Profile schema v1 (map keyed by census name — see MAPPING-SCHEMA.md)
struct ProfileEntryJ: Codable {
    let action: String
    let text: String?; let chord: String?; let keys: [String]?
    let cw: String?; let ccw: String?; let command: String?
    let mode: String?; let invert: Bool?
    let note: Int?; let cc: Int?; let label: String?
}
struct ProfileFileJ: Codable {
    let app: String?; let chime: String?; var controls: [String: ProfileEntryJ]
}
struct DeckStateJ: Codable { var active: String? }

// MARK: - Control catalog

struct MidiId: Codable, Equatable, Hashable {
    var isNote: Bool
    var num: Int
    var text: String { (isNote ? "note " : "CC ") + String(num) }
}

enum Family {
    case keyboard      // velocity-sensitive musical key → note
    case encoder       // endless, clickable: two slots (turn CC + click CC)
    case pot           // finite knob, no click (main/volume)
    case button        // non-velocity key → note or CC, single action
    case decor         // speaker, screen — not clickable
}

struct Control: Identifiable {
    let id: String
    let name: String
    let family: Family
    let frame: CGRect          // in SVG artwork units (viewBox 741 × 265)
    var round = false
    var glyph = ""
    var chromatic: Int? = nil  // keyboard: semitone offset from key F (base 53)
    var dia: CGFloat = 24.1    // control circle diameter in SVG units (for overlays)
}

// TE artwork coordinate system, derived from the official SVG's path data:
// 17-column grid, pitch 39.797, six 39.8-high rows. Hotspots computed in these
// units align with the art by construction.
let ART_W: CGFloat = 741, ART_H: CGFloat = 265
let GRID_X0 = 12.06, GRID_COL = 39.797
let GRID_ROWY: [Double] = [11.77, 51.80, 91.61, 131.42, 171.21, 211.01, 250.81]

let KEY_ACTIONS = ["none", "ptt", "submit", "esc", "model_picker", "effort_command", "thinking_toggle", "shell", "type", "key", "profile_cycle"]
let KNOB_ACTIONS = ["none", "select", "effort", "scroll", "scroll_page"]  // "turn" (cw/ccw chords) is agent/JSON-only for now
let KEYBOARD_BASE_DEFAULT = 53  // leftmost white key = F, learned 2026-07-15

func catalog() -> [Control] {
    var c: [Control] = []
    // A grid cell (col 0–16, row 0–5 = A–F), optionally spanning multiple cells.
    func cell(_ col: Int, _ row: Int, w: Int = 1, h: Int = 1) -> CGRect {
        CGRect(x: GRID_X0 + Double(col) * GRID_COL, y: GRID_ROWY[row],
               width: GRID_COL * Double(w), height: GRID_ROWY[row + h] - GRID_ROWY[row])
    }

    // top strip
    c.append(Control(id: "speaker", name: "speaker", family: .decor, frame: cell(0, 0, w: 2, h: 2)))
    c.append(Control(id: "main_knob", name: "main knob (volume)", family: .pot,
                     frame: cell(2, 0), round: true, dia: 28.2))  // knob sits in the LEFT cell of its 2-cell box
    c.append(Control(id: "key_pen", name: "pen key", family: .button, frame: cell(2, 1), round: true, glyph: "✒︎"))
    c.append(Control(id: "key_metronome", name: "metronome key", family: .button, frame: cell(3, 1), round: true, glyph: "⏱"))
    c.append(Control(id: "screen", name: "display", family: .decor, frame: cell(4, 0, w: 4, h: 2)))
    for i in 0..<4 {
        c.append(Control(id: "enc\(i + 1)", name: "encoder \(i + 1)", family: .encoder,
                         frame: cell(8 + i * 2, 0, w: 2, h: 2), round: true, glyph: "\(i + 1)", dia: 43.6))
    }
    c.append(Control(id: "key_audio", name: "audio key", family: .button, frame: cell(16, 0), round: true, glyph: "◍"))
    c.append(Control(id: "key_com", name: "com key", family: .button, frame: cell(16, 1), round: true, glyph: "com"))

    // module/track row (16) + sequencer key — all circular keys on the device
    let modGlyphs = ["∿", "⌁", "▭", "≣", "1", "2", "3", "4", "1♪", "2♨", "3◴", "4cv", "5⌾", "6∞", "7fx", "8fx"]
    for i in 0..<16 {
        c.append(Control(id: "mod\(i + 1)", name: "module key \(i + 1)", family: .button,
                         frame: cell(i, 2), round: true, glyph: modGlyphs[i]))
    }
    c.append(Control(id: "key_seq", name: "sequencer key", family: .button, frame: cell(16, 2), round: true, glyph: "⋰"))

    // step keys (16) + bar key
    for i in 0..<16 {
        c.append(Control(id: "step\(i + 1)", name: "step key \(i + 1)", family: .button,
                         frame: cell(i, 3), round: true))
    }
    c.append(Control(id: "key_bar", name: "bar 1–4 key", family: .button, frame: cell(16, 3), round: true, glyph: "1-4"))

    // transport + black keys (num row)
    let transport = [("record", "⏺"), ("play", "▶"), ("stop", "▦")]
    for (i, t) in transport.enumerated() {
        c.append(Control(id: "transport.\(t.0)", name: t.0, family: .button,
                         frame: cell(i, 4), round: true, glyph: t.1))
    }
    // Black keys sit on white-key boundaries; centers taken from the artwork.
    let blackCx: [Double] = [171.46, 211.24, 251.03, 330.60, 370.39, 449.97, 489.75, 529.54, 609.11, 648.90]
    let blackOffsets = [1, 3, 5, 8, 10, 13, 15, 17, 20, 22]  // semitones from F
    let numGlyphs = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    for k in 0..<10 {
        c.append(Control(id: "kb.b\(k)", name: "key num \(numGlyphs[k])", family: .keyboard,
                         frame: CGRect(x: blackCx[k] - GRID_COL / 2, y: GRID_ROWY[4],
                                       width: GRID_COL, height: GRID_ROWY[5] - GRID_ROWY[4]),
                         round: true, glyph: numGlyphs[k], chromatic: blackOffsets[k]))
    }

    // bottom row: -, +, shift, then 14 white keys
    let fnGlyphs = [("key_minus", "−"), ("key_plus", "+"), ("key_shift", "shift")]
    for (i, f) in fnGlyphs.enumerated() {
        c.append(Control(id: f.0, name: f.0.replacingOccurrences(of: "key_", with: "") + " key", family: .button,
                         frame: cell(i, 5), round: true, glyph: f.1))
    }
    let whiteOffsets = [0, 2, 4, 6, 7, 9, 11, 12, 14, 16, 18, 19, 21, 23]
    let whiteGlyphs = ["⁘", "✋", "÷", "◢", "⌸", "◿", "rnd", "⤴", "◭", "❋", "→", "◔", "❊", "☀"]
    for w in 0..<14 {
        c.append(Control(id: "kb.w\(w)", name: "key \(whiteGlyphs[w])", family: .keyboard,
                         frame: cell(3 + w, 5), round: true, glyph: whiteGlyphs[w], chromatic: whiteOffsets[w]))
    }
    return c
}

// MARK: - MIDI input

struct MidiMsg: Identifiable {
    let id = UUID()
    let kind: String  // note-on | note-off | cc
    let a: Int, b: Int
    var text: String { "\(kind) \(a) \(b)" }
}

final class MidiEngine: ObservableObject {
    @Published var log: [MidiMsg] = []
    @Published var opxyConnected = false
    var onEvent: ((MidiMsg) -> Void)?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    func start() {
        MIDIClientCreateWithBlock("opxy-mapper" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.drain(list)
        }
        connectAll()
    }

    private var nameMatched = false
    private var everReceived = false

    func connectAll() {
        var found = false
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            // DisplayName combines device + endpoint names (BLE endpoints often
            // carry a bare/odd kMIDIPropertyName, which is why plain Name fails).
            var nm = ""
            for prop in [kMIDIPropertyDisplayName, kMIDIPropertyName] {
                var un: Unmanaged<CFString>?
                if MIDIObjectGetStringProperty(src, prop, &un) == noErr,
                   let s = un?.takeRetainedValue() as String? { nm = s; break }
            }
            names.append(nm.isEmpty ? "(unnamed)" : nm)
            let l = nm.lowercased()
            if l.contains("xy") || l.contains("teenage") { found = true }
        }
        print("midi sources (\(names.count)): \(names.joined(separator: " | "))")
        nameMatched = found
        recompute()
    }

    // Connected = name recognized, OR we've received events and sources still exist
    // (sticky: an untouched deck must not flip the indicator red).
    func recompute() {
        opxyConnected = nameMatched || (everReceived && MIDIGetNumberOfSources() > 0)
    }

    func noteReceived() {
        if !everReceived { everReceived = true; recompute() }
    }

    private func drain(_ listPtr: UnsafePointer<MIDIEventList>) {
        var msgs: [MidiMsg] = []
        var packet = listPtr.pointee.packet
        for p in 0..<Int(listPtr.pointee.numPackets) {
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for w in 0..<Int(packet.wordCount) {
                    let word = words[w]
                    guard (word >> 28) == 0x2 else { continue }
                    let status = Int((word >> 16) & 0xF0)
                    let d1 = Int((word >> 8) & 0x7F), d2 = Int(word & 0x7F)
                    switch status {
                    case 0x90: msgs.append(MidiMsg(kind: d2 > 0 ? "note-on" : "note-off", a: d1, b: d2))
                    case 0x80: msgs.append(MidiMsg(kind: "note-off", a: d1, b: d2))
                    case 0xB0: msgs.append(MidiMsg(kind: "cc", a: d1, b: d2))
                    default: break
                    }
                }
            }
            if p < Int(listPtr.pointee.numPackets) - 1 {
                packet = withUnsafePointer(to: packet) { MIDIEventPacketNext($0).pointee }
            }
        }
        guard !msgs.isEmpty else { return }
        DispatchQueue.main.async {
            self.noteReceived()
            for m in msgs {
                print("midi: \(m.text)")
                self.log.insert(m, at: 0)
                self.onEvent?(m)
            }
            if self.log.count > 6 { self.log.removeLast(self.log.count - 6) }
        }
    }
}

// MARK: - BLE auto-connect
// The OP-XY must be told to advertise (com → click the dark grey encoder) — that
// part is firmware. But the Mac side is automated here: scan for the standard
// BLE-MIDI service, connect the moment the OP-XY appears; macOS's Bluetooth-MIDI
// driver then creates the CoreMIDI device (same thing Audio MIDI Setup's dialog
// does, minus the dialog). Re-scans automatically after disconnects.

let MIDI_BLE_SERVICE = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")

final class BLEAutoConnector: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var status = "BT: off"
    @Published var active = false
    @Published var advertising = false     // OP-XY seen advertising BLE-MIDI
    private var central: CBCentralManager?
    private var midiWC: NSWindowController?

    // CoreBluetooth is used ONLY to detect the OP-XY advertising (reliable — this
    // is the flaky part in Audio MIDI Setup) so we can highlight the connect
    // button at the right moment. We do NOT hold the GATT link: connecting via
    // raw CoreBluetooth never creates a CoreMIDI endpoint and can block the system
    // MIDI driver. The real connection is made through the system window below,
    // which macOS remembers and auto-reconnects on later advertises.
    func start() {
        guard central == nil else { return }
        active = true
        status = "BT: starting…"
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: startScan()
        case .unauthorized: status = "BT: permission denied (System Settings → Privacy → Bluetooth)"
        case .poweredOff: status = "BT: Bluetooth is off"
        default: status = "BT: …"
        }
    }

    private func startScan() {
        guard let central, central.state == .poweredOn else { return }
        advertising = false
        status = "BT: scanning for OP-XY…"
        central.scanForPeripherals(withServices: [MIDI_BLE_SERVICE], options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").lowercased()
        guard name.contains("op") else { return }
        if !advertising { print("ble: OP-XY advertising") }
        advertising = true
        status = "BT: OP-XY advertising — click Connect Bluetooth MIDI"
    }

    // Opens the system Bluetooth-MIDI window (the same list Audio MIDI Setup
    // shows, summoned directly). Connecting there creates the CoreMIDI device;
    // macOS remembers it and auto-reconnects when the OP-XY advertises again.
    func presentSystemMIDIWindow() {
        let wc = CABTLEMIDIWindowController()
        midiWC = wc
        wc.showWindow(nil)
        wc.window?.center()
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Bridge runner (run/stop the pipeline from the GUI)

final class BridgeRunner: ObservableObject {
    @Published var running = false
    var onLog: ((String) -> Void)?
    private var recv: Process?
    private var bridge: Process?

    func start(dir: String) {
        stop()
        let r = Process()
        r.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        r.arguments = ["receivemidi", "dev", "OP-XY", "nn"]
        let mid = Pipe()
        r.standardOutput = mid
        r.standardError = FileHandle.nullDevice

        let b = Process()
        b.executableURL = URL(fileURLWithPath: dir + "/opxy-bridge")
        b.arguments = []   // active profile from deck-state.json; hot-reloads on edit/switch
        b.currentDirectoryURL = URL(fileURLWithPath: dir)
        b.standardInput = mid
        let err = Pipe()
        b.standardError = err
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            DispatchQueue.main.async {
                for line in s.split(separator: "\n") { self?.onLog?(String(line)) }
            }
        }
        b.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { if self?.running == true { self?.stopped() } }
        }
        do {
            try r.run(); try b.run()
            recv = r; bridge = b; running = true
            onLog?("bridge started")
        } catch {
            onLog?("bridge start FAILED: \(error.localizedDescription)")
            r.terminate()
        }
    }

    func stop() {
        recv?.terminate(); bridge?.terminate()
        recv = nil; bridge = nil
        if running { stopped() }
    }
    private func stopped() { running = false; onLog?("bridge stopped") }
}

// MARK: - App state

struct Assign: Equatable { var action = "none"; var command = ""; var invert = false }

final class Store: ObservableObject {
    @Published var idents: [String: MidiId] = [:]  // slot id → MIDI identity
    @Published var assigns: [String: Assign] = [:] // slot id → assignment
    @Published var selected: String?               // selected slot id
    @Published var armed: String?                  // slot waiting for identify
    @Published var flash: String?
    @Published var dirty = false
    @Published var status = "ready"

    let controls = catalog()
    // Repo dir: when running as a bundled .app inside the repo, cwd is "/" —
    // use the bundle's parent directory instead.
    let dir: String = {
        let bundle = Bundle.main.bundlePath
        if bundle.hasSuffix(".app") {
            return URL(fileURLWithPath: bundle).deletingLastPathComponent().path
        }
        return FileManager.default.currentDirectoryPath
    }()
    var mappingURL: URL { URL(fileURLWithPath: dir + "/mapping.json") }  // legacy v0 fallback
    var identsURL: URL { URL(fileURLWithPath: dir + "/opxy-controls.json") }

    // Profiles (schema v1): private ~/.config/opxy-deck/profiles beats bundled <repo>/profiles.
    // Keep path logic in sync with opxy-bridge.swift.
    let configDir = ProcessInfo.processInfo.environment["OPXY_CONFIG_DIR"]
        ?? (NSHomeDirectory() + "/.config/opxy-deck")
    @Published var profileName = "claude-code"
    var profileApp: String?
    var profileChime: String?
    var rawEntries: [String: ProfileEntryJ] = [:]   // full decoded entry per owned slot (keeps payloads the GUI doesn't edit)
    var preserved: [String: ProfileEntryJ] = [:]    // entries we can't own (unknown control names/identities)

    func readActiveName() -> String {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: configDir + "/deck-state.json")),
              let s = try? JSONDecoder().decode(DeckStateJ.self, from: d),
              let a = s.active, !a.isEmpty else { return "claude-code" }
        return a
    }

    func availableProfiles() -> [String] {
        var names = Set<String>()
        for d in [configDir + "/profiles", dir + "/profiles"] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".json") {
                names.insert(String(f.dropLast(5)))
            }
        }
        return names.isEmpty ? [profileName] : names.sorted()
    }

    func profileURL(_ name: String) -> URL {
        let local = configDir + "/profiles/" + name + ".json"
        if FileManager.default.fileExists(atPath: local) { return URL(fileURLWithPath: local) }
        return URL(fileURLWithPath: dir + "/profiles/" + name + ".json")
    }

    // Switch active profile: write deck-state.json (the running bridge follows via its
    // own watcher) and reload the panel. Unsaved edits are discarded.
    func switchProfile(_ name: String) {
        guard name != profileName else { return }
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? enc.encode(DeckStateJ(active: name)))?
            .write(to: URL(fileURLWithPath: configDir + "/deck-state.json"))
        profileName = name
        loadProfile()
    }

    // Optional artwork skin: assets/opxy.pdf (converted from TE's SVG by `make gui`).
    // Present → the real panel art with transparent hotspots; absent → self-drawn panel.
    @Published var skin: NSImage? = nil
    func loadSkin() {
        for name in ["assets/opxy.pdf", "assets/opxy.png"] {
            if let img = NSImage(contentsOfFile: dir + "/" + name) { skin = img; break }
        }
        print("skin: \(skin != nil ? "loaded" : "none") (dir \(dir))")
    }

    // Slot ids: keyboard/button = control.id; encoder = "enc1.turn" / "enc1.click".
    func control(for slot: String) -> Control? {
        let base = slot.split(separator: ".").first.map(String.init) ?? slot
        return controls.first { $0.id == base || $0.id == slot }
    }
    func isTurnSlot(_ slot: String) -> Bool { slot.hasSuffix(".turn") }

    func seedIdentities() {
        // Full OP-XY controller-mode emit map, captured from Kaz's device 2026-07-15.
        // Main knob transmits NOTHING in controller mode (stays hardware volume).
        var d: [String: MidiId] = [:]
        for c in controls {
            if let off = c.chromatic { d[c.id] = MidiId(isNote: true, num: KEYBOARD_BASE_DEFAULT + off) }
        }
        func cc(_ slot: String, _ n: Int) { d[slot] = MidiId(isNote: false, num: n) }
        cc("enc1.turn", 1); cc("enc2.turn", 2); cc("enc3.turn", 3); cc("enc4.turn", 4)
        cc("key_pen", 5); cc("key_metronome", 6)
        for i in 0..<8 { cc("mod\(i + 1)", 7 + i) }          // module 1-8 = CC 7-14
        cc("enc1.click", 15); cc("enc2.click", 16)
        cc("enc3.click", 17); cc("enc4.click", 18)           // inferred: CC gap 15-18
        for i in 8..<16 { cc("mod\(i + 1)", 11 + i) }        // module 9-16 = CC 19-26
        cc("key_seq", 27); cc("key_audio", 28); cc("key_com", 29); cc("key_bar", 30)
        cc("transport.record", 55); cc("transport.play", 56); cc("transport.stop", 57)
        cc("key_minus", 58); cc("key_plus", 59); cc("key_shift", 60)  // shift inferred
        for i in 0..<16 { cc("step\(i + 1)", 61 + i) }       // steps = CC 61-76
        idents = d
    }

    func isPot(_ slot: String) -> Bool {
        if case .pot = control(for: slot)?.family { return true }
        return false
    }

    // Drop conflicting identities (e.g. a pot mis-learned as a keyboard note).
    func sanitizeIdentities() {
        var seen: [MidiId: String] = [:]
        for (slot, mid) in idents.sorted(by: { $0.key < $1.key }) {
            if let other = seen[mid] {
                let drop = isPot(slot) ? slot : isPot(other) ? other : slot
                idents.removeValue(forKey: drop)
                if drop == other { seen[mid] = slot }
                status = "dropped conflicting identity: \(drop) duplicated \(mid.text)"
            } else {
                seen[mid] = slot
            }
        }
    }

    func load() {
        loadSkin()
        seedIdentities()
        if let d = try? Data(contentsOf: identsURL),
           let saved = try? JSONDecoder().decode([String: MidiId].self, from: d) {
            idents.merge(saved) { _, new in new }
        }
        sanitizeIdentities()
        profileName = readActiveName()
        loadProfile()
    }

    func loadProfile() {
        assigns = [:]; rawEntries = [:]; preserved = [:]
        profileApp = nil; profileChime = nil
        dirty = false
        let url = profileURL(profileName)
        if let d = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode(ProfileFileJ.self, from: d) {
            profileApp = p.app; profileChime = p.chime
            for (name, e) in p.controls {
                let resolved: String? = {
                    if idents[name] != nil { return name }          // census-named entry
                    if let n = e.note { return slot(for: MidiId(isNote: true, num: n)) }
                    if let c = e.cc { return slot(for: MidiId(isNote: false, num: c)) }
                    return nil
                }()
                guard let s = resolved else { preserved[name] = e; continue }
                rawEntries[s] = e
                let payload = e.command ?? e.text ?? e.chord ?? ""
                assigns[s] = Assign(action: e.action, command: payload, invert: e.invert ?? false)
            }
            status = "profile: \(profileName) (\(p.controls.count) controls)"
            return
        }
        // Legacy fallback: v0 mapping.json arrays (pre-profiles checkout)
        guard let d = try? Data(contentsOf: mappingURL),
              let m = try? JSONDecoder().decode(MappingJ.self, from: d) else {
            status = "profile: \(profileName) (new — nothing mapped yet)"
            return
        }
        for k in m.keys {
            if let slot = slot(for: MidiId(isNote: true, num: k.note)) {
                assigns[slot] = Assign(action: k.action, command: k.command ?? "", invert: false)
            }
        }
        for k in m.knobs {
            if let slot = slot(for: MidiId(isNote: false, num: k.cc)), isTurnSlot(slot) || control(for: slot)?.chromatic == nil {
                assigns[slot] = Assign(action: k.action, command: "", invert: k.invert ?? false)
            }
        }
        for b in m.buttons ?? [] {
            if let slot = slot(for: MidiId(isNote: false, num: b.cc)) {
                assigns[slot] = Assign(action: b.action, command: b.command ?? "", invert: false)
            }
        }
        status = "loaded legacy mapping.json — Save writes profile \(profileName)"
    }

    func slot(for id: MidiId) -> String? { idents.first(where: { $0.value == id })?.key }

    func handle(_ m: MidiMsg) {
        let id: MidiId? = {
            switch m.kind {
            case "note-on": return MidiId(isNote: true, num: m.a)
            case "cc" where m.b > 0: return MidiId(isNote: false, num: m.a)
            default: return nil
            }
        }()
        if let armedSlot = armed {
            guard let mid = id else { return }
            // Encoder turn learn accepts mid-range CC; click learn accepts 127.
            if isTurnSlot(armedSlot), mid.isNote || m.b == 127 || m.b == 0 { return }
            if armedSlot.hasSuffix(".click"), mid.isNote || m.b != 127 { return }
            idents[armedSlot] = mid
            // Keyboard chromatic inference: one key re-seeds all 24.
            if let c = control(for: armedSlot), let off = c.chromatic, mid.isNote {
                let base = mid.num - off
                for k in controls where k.chromatic != nil {
                    idents[k.id] = MidiId(isNote: true, num: base + k.chromatic!)
                }
                status = "keyboard placed — key F = note \(base) (all 24 set)"
            } else {
                status = "\(control(for: armedSlot)?.name ?? armedSlot) = \(mid.text)"
            }
            armed = nil; dirty = true; saveIdents()
            return
        }
        if let mid = id, let slot = slot(for: mid) {
            flash = slot
            selected = slot
            let s = slot
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if self.flash == s { self.flash = nil } }
        }
    }

    func saveIdents() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? enc.encode(idents))?.write(to: identsURL)
    }

    // Write the active profile (schema v1). Preserves: entries we couldn't own, and the
    // payload fields the GUI doesn't edit (keys sequences, cw/ccw, mode) for untouched
    // actions — so agent-authored entries survive a GUI save.
    func save() {
        var controls = preserved
        for (slot, a) in assigns where a.action != "none" {
            guard idents[slot] != nil, control(for: slot) != nil else { continue }
            if let raw = rawEntries[slot], raw.action == a.action,
               a.command.isEmpty || a.command == (raw.command ?? raw.text ?? raw.chord ?? "") {
                controls[slot] = ProfileEntryJ(
                    action: raw.action, text: raw.text, chord: raw.chord, keys: raw.keys,
                    cw: raw.cw, ccw: raw.ccw, command: raw.command, mode: raw.mode,
                    invert: isTurnSlot(slot) ? (a.invert ? true : nil) : raw.invert,
                    note: raw.note, cc: raw.cc, label: raw.label)
                continue
            }
            let isKnob = isTurnSlot(slot)
            controls[slot] = ProfileEntryJ(
                action: a.action,
                text: a.action == "type" ? a.command : nil,
                chord: a.action == "key" ? a.command : nil,
                keys: nil, cw: nil, ccw: nil,
                command: a.action == "shell" ? a.command : nil,
                mode: isKnob ? (rawEntries[slot]?.mode ?? "absolute") : nil,
                invert: isKnob && a.invert ? true : nil,
                note: nil, cc: nil,   // slot ids are census names; the bridge resolves them
                label: nil)
        }
        let url = profileURL(profileName)
        try? FileManager.default.createDirectory(
            atPath: url.deletingLastPathComponent().path, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(ProfileFileJ(app: profileApp, chime: profileChime, controls: controls))
                .write(to: url)
            saveIdents()
            dirty = false
            status = "saved \(profileName) (\(controls.count) controls)\(checkVerdict(url))"
            print("saved \(url.path): \(controls.count) controls")
        } catch { status = "SAVE FAILED: \(error.localizedDescription)" }
    }

    // Validate with the engine's own checker so GUI saves get the same gate as agent edits.
    private func checkVerdict(_ url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dir + "/opxy-bridge")
        p.arguments = ["--check", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }   // no bridge binary → skip
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus == 0 {
            let warns = out.split(separator: "\n").filter { $0.hasPrefix("warning") }.count
            return warns > 0 ? " — check OK, \(warns) warning(s), see console" : " — check OK"
        }
        let firstErr = out.split(separator: "\n").first(where: { $0.hasPrefix("error") }) ?? "see console"
        return " — CHECK FAILED: \(firstErr)"
    }
}

// MARK: - Panel view

struct PanelView: View {
    @ObservedObject var store: Store
    @Binding var encSlotIsClick: Bool

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / ART_W   // SVG units → view points
            ZStack {
                if let skin = store.skin {
                    Image(nsImage: skin)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 12 * s).fill(Color(white: 0.055))
                    RoundedRectangle(cornerRadius: 12 * s).stroke(Color(white: 0.3), lineWidth: 1)
                }
                ForEach(store.controls) { c in
                    let r = CGRect(x: c.frame.minX * s, y: c.frame.minY * s,
                                   width: c.frame.width * s, height: c.frame.height * s)
                    controlView(c, rect: r, scale: s)
                        .position(x: r.midX, y: r.midY)
                }
            }
        }
        .aspectRatio(ART_W / ART_H, contentMode: .fit)
    }

    @ViewBuilder
    func controlView(_ c: Control, rect: CGRect, scale: CGFloat) -> some View {
        let slot: String = {
            if case .encoder = c.family { return c.id + (encSlotIsClick ? ".click" : ".turn") }
            return c.id
        }()
        let selectedSlot = store.selected
        let isSel = selectedSlot == slot || (selectedSlot?.hasPrefix(c.id + ".") ?? false)
        let isFlash = store.flash.map { $0 == c.id || $0.hasPrefix(c.id + ".") } ?? false
        let isArmed = store.armed.map { $0 == c.id || $0.hasPrefix(c.id + ".") } ?? false
        let assigned: Bool = {
            if case .encoder = c.family {
                return (store.assigns[c.id + ".turn"]?.action ?? "none") != "none"
                    || (store.assigns[c.id + ".click"]?.action ?? "none") != "none"
            }
            return (store.assigns[c.id]?.action ?? "none") != "none"
        }()
        let known = store.idents[slot] != nil || store.idents[c.id] != nil

        let fill: Color = isFlash ? Color.yellow.opacity(0.85)
            : assigned ? Color.accentColor.opacity(0.5)
            : Color(white: known ? 0.16 : 0.09)
        let stroke: Color = isArmed ? .orange : isSel ? .white : Color(white: 0.42)
        let lw: CGFloat = (isSel || isArmed) ? 2 : 1

        Group {
            if store.skin != nil {
                // Artwork mode: the art draws the device; we render only state overlays
                // as circles matched to each control's printed circle.
                if case .decor = c.family {
                    Color.clear.frame(width: rect.width, height: rect.height)
                } else {
                    let d = c.dia * scale
                    ZStack {
                        Circle().fill(isFlash ? Color.yellow.opacity(0.45)
                                     : assigned ? Color.accentColor.opacity(0.30) : Color.clear)
                        if isSel || isArmed {
                            Circle().stroke(isArmed ? Color.orange : Color.white, lineWidth: 2)
                        }
                    }
                    .frame(width: d, height: d)
                    .frame(width: rect.width, height: rect.height)  // full-cell hit area
                }
            } else {
            switch c.family {
            case .decor:
                if c.id == "speaker" {
                    SpeakerDots().stroke(Color(white: 0.4), lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.02))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.35), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                }
            case .encoder:
                ZStack {
                    Circle().fill(fill)
                    Circle().stroke(stroke, lineWidth: lw)
                    Circle().stroke(Color(white: 0.35), lineWidth: 1).padding(rect.width * 0.18)
                    Text(c.glyph).font(.system(size: rect.width * 0.16)).foregroundColor(.secondary)
                }
                .frame(width: min(rect.width, rect.height), height: min(rect.width, rect.height))
            case .pot, .button, .keyboard:
                if c.round {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.02))
                        RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.3), lineWidth: 1)
                        Circle().fill(fill).padding(3)
                        Circle().stroke(stroke, lineWidth: lw).padding(3)
                        Text(c.glyph).font(.system(size: rect.height * 0.28)).foregroundColor(.secondary)
                    }
                    .frame(width: rect.width, height: rect.height)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(fill)
                        RoundedRectangle(cornerRadius: 5).stroke(stroke, lineWidth: lw)
                        Text(c.glyph).font(.system(size: min(11, rect.height * 0.3)))
                            .foregroundColor(Color(white: 0.75))
                    }
                    .frame(width: rect.width, height: rect.height)
                }
            }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch c.family {
            case .decor:
                return
            case .pot:
                store.selected = c.id   // selectable for info; never armed (doesn't transmit)
            case .encoder:
                store.selected = c.id + (encSlotIsClick ? ".click" : ".turn")
                let s = store.selected!
                if store.idents[s] == nil {
                    store.armed = s
                    store.status = "press / turn \(c.name) on the OP-XY now…"
                }
            default:
                store.selected = c.id
                if store.idents[c.id] == nil {
                    store.armed = c.id
                    store.status = "press \(c.name) on the OP-XY now…"
                }
            }
        }
    }
}

struct SpeakerDots: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cols = 9, rows = 7
        for r in 0..<rows {
            for cIdx in 0..<cols {
                // rounded speaker-grid corners
                let dc = abs(cIdx - cols / 2), dr = abs(r - rows / 2)
                if dc + dr > 7 { continue }
                let x = rect.minX + rect.width * (Double(cIdx) + 0.5) / Double(cols)
                let y = rect.minY + rect.height * (Double(r) + 0.5) / Double(rows)
                let rad = min(rect.width, rect.height) * 0.035
                p.addEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
            }
        }
        return p
    }
}

// MARK: - Detail panel

struct DetailPanel: View {
    @ObservedObject var store: Store
    @Binding var encSlotIsClick: Bool

    // Horizontal configuration bar, shown beneath the device panel.
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let slot = store.selected, let c = store.control(for: slot) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.headline)
                    Text(familyText(c)).font(.caption2).foregroundColor(.secondary)
                }
                .frame(width: 195, alignment: .leading)
                Divider().frame(height: 40)

                if case .pot = c.family {
                    Text("Sends no MIDI in controller mode — stays the OP-XY's own hardware volume (the dial for future status sounds).")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    if case .encoder = c.family {
                        Picker("", selection: $encSlotIsClick) {
                            Text("turn").tag(false); Text("click").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                        .onChange(of: encSlotIsClick) { v in store.selected = c.id + (v ? ".click" : ".turn") }
                    }
                    let effSlot = { () -> String in
                        if case .encoder = c.family { return c.id + (encSlotIsClick ? ".click" : ".turn") }
                        return c.id
                    }()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.idents[effSlot]?.text ?? "identity unknown")
                            .font(.caption).foregroundColor(store.idents[effSlot] == nil ? .orange : .secondary)
                        Button(store.armed == effSlot ? "waiting… (touch it)" : "learn") {
                            store.armed = effSlot
                            store.status = "touch \(c.name) on the OP-XY now…"
                        }.font(.caption)
                    }
                    .frame(width: 130, alignment: .leading)

                    let isTurn = store.isTurnSlot(effSlot)
                    let binding = Binding<Assign>(
                        get: { store.assigns[effSlot] ?? Assign() },
                        set: { store.assigns[effSlot] = $0; store.dirty = true }
                    )
                    Picker("action", selection: binding.action) {
                        ForEach(isTurn ? KNOB_ACTIONS : KEY_ACTIONS, id: \.self) { Text($0) }
                    }
                    .frame(width: 230)
                    if ["shell", "type", "key"].contains(binding.wrappedValue.action) {
                        TextField(binding.wrappedValue.action == "shell" ? "shell command…"
                                  : binding.wrappedValue.action == "type" ? "text to type… (\\n = Enter)"
                                  : "key chord… (M-t, C-c, Enter, S-Left)",
                                  text: binding.command)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                            .frame(minWidth: 200, maxWidth: 340)
                    }
                    if isTurn {
                        Toggle("invert", isOn: binding.invert).font(.caption)
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer()
                Text("click a control on the panel — or touch it on the OP-XY")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(Color(white: 0.1))
        .cornerRadius(8)
    }

    func familyText(_ c: Control) -> String {
        switch c.family {
        case .keyboard: return "musical key · velocity-sensitive · note"
        case .encoder: return "endless encoder · clickable"
        case .pot: return "finite knob · no click"
        case .button: return "key · no velocity"
        case .decor: return ""
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject var store = Store()
    @StateObject var midi = MidiEngine()
    @StateObject var bridge = BridgeRunner()
    @StateObject var ble = BLEAutoConnector()
    @State var encSlotIsClick = false
    @State var bridgeLog: [String] = []
    @State var showConsole = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("OP-XY Claude Deck").font(.title3).bold()
                Picker("", selection: Binding(
                    get: { store.profileName },
                    set: { store.switchProfile($0) }
                )) {
                    ForEach(store.availableProfiles(), id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 160)
                .help("Active profile (deck-state.json). Switching applies live — a running bridge follows. Unsaved edits are discarded.")
                Circle().fill(midi.opxyConnected ? .green : .red).frame(width: 9, height: 9)
                Text(midi.opxyConnected ? "OP-XY connected" : "OP-XY not found")
                    .font(.caption).foregroundColor(.secondary)
                if !midi.opxyConnected {
                    Button(ble.advertising ? "Connect Bluetooth MIDI ●" : "Connect Bluetooth MIDI") {
                        ble.presentSystemMIDIWindow()
                    }
                    .font(.caption).controlSize(.small)
                    .tint(ble.advertising ? .blue : nil)
                    .help("Opens the system Bluetooth-MIDI window. Connect once; macOS then auto-reconnects the OP-XY when it advertises.")
                    if ble.active {
                        Text(ble.status).font(.caption2).foregroundColor(.secondary.opacity(0.8))
                    }
                }
                Spacer()
                Button(showConsole ? "console ▾" : "console ▸") { showConsole.toggle() }
                    .font(.caption)
                Button(bridge.running ? "◼ Stop bridge" : "▶ Run bridge") {
                    bridge.running ? bridge.stop() : bridge.start(dir: store.dir)
                }
                .tint(bridge.running ? .red : .green)
                Button(store.dirty ? "Save ●" : "Save") {
                    store.save()
                    if bridge.running { store.status += " — bridge hot-reloads" }
                }
                .keyboardShortcut("s")
            }

            Spacer(minLength: 0)
            PanelView(store: store, encSlotIsClick: $encSlotIsClick)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 0)

            DetailPanel(store: store, encSlotIsClick: $encSlotIsClick)

            if showConsole {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("midi").font(.caption2).foregroundColor(.secondary.opacity(0.6))
                        ForEach(midi.log) { m in
                            Text(m.text).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                    .padding(6).background(Color(white: 0.08)).cornerRadius(6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("bridge — keystrokes need Accessibility for this app when run from here")
                            .font(.caption2).foregroundColor(.secondary.opacity(0.6))
                        ForEach(bridgeLog.indices, id: \.self) { i in
                            Text(bridgeLog[i]).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                    .padding(6).background(Color(white: 0.08)).cornerRadius(6)
                }
            }
            HStack {
                Text(store.status).font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 1040, minHeight: 560)
        .preferredColorScheme(.dark)
        .onAppear {
            setvbuf(stdout, nil, _IOLBF, 0)
            store.load()
            midi.onEvent = { store.handle($0) }
            midi.start()
            bridge.onLog = { line in
                bridgeLog.insert(line, at: 0)
                if bridgeLog.count > 6 { bridgeLog.removeLast(bridgeLog.count - 6) }
                print(line)
            }
            // Auto-scan for advertising only when BT is already authorized (no
            // prompt, no TCC risk). Otherwise the Connect button opens the system
            // window, which handles Bluetooth itself. OPXY_NO_BLE=1 skips it (tests).
            if ProcessInfo.processInfo.environment["OPXY_NO_BLE"] == nil,
               CBManager.authorization == .allowedAlways {
                ble.start()
            }
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct OpxyMapperApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
