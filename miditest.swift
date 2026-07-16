// miditest — persistent virtual MIDI source for testing the mapper/bridge without
// the OP-XY. Creates source "opxy-test", emits a fixed sequence every 0.5s, exits
// after ~5s. Usage: swiftc -O miditest.swift -o miditest && ./miditest

import Foundation
import CoreMIDI

var client = MIDIClientRef()
MIDIClientCreate("miditest" as CFString, nil, nil, &client)
var source = MIDIEndpointRef()
let status = MIDISourceCreateWithProtocol(client, "opxy-test" as CFString, ._1_0, &source)
guard status == noErr else { print("source create failed: \(status)"); exit(1) }
print("virtual source 'opxy-test' up")

func send(_ st: UInt32, _ d1: UInt32, _ d2: UInt32) {
    let word: UInt32 = (0x2 << 28) | (st << 16) | (d1 << 8) | d2
    var list = MIDIEventList()
    let packet = MIDIEventListInit(&list, ._1_0)
    _ = MIDIEventListAdd(&list, 1024, packet, 0, 1, [word])
    MIDIReceivedEventList(source, &list)
}

sleep(2)  // give listeners time to notice the new source and connect
// record press/release, knob1 turn, piano note 60 on/off
let seq: [(UInt32, UInt32, UInt32, String)] = [
    (0xB0, 55, 127, "cc 55 127 (record press)"),
    (0xB0, 55, 0,   "cc 55 0   (record release)"),
    (0xB0, 1, 42,   "cc 1 42   (knob1 turn)"),
    (0x90, 60, 100, "note-on 60"),
    (0x80, 60, 0,   "note-off 60"),
]
for (st, d1, d2, desc) in seq {
    send(st, d1, d2)
    print("sent \(desc)")
    usleep(400_000)
}
sleep(1)
print("done")
