// Prints MIDI messages from sources whose name contains a text (default "Rocksmith Companion"),
// one line each: time, source, bytes and a label. Connects to matching sources as they appear.
// Build: swiftc -O tools/midi_monitor.swift -o build/midi_monitor
// Usage: build/midi_monitor ["source name part"]
import CoreMIDI
import Foundation

let match = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Rocksmith Companion"
var client = MIDIClientRef()
var port = MIDIPortRef()
var connected = Set<MIDIEndpointRef>()

func name(_ endpoint: MIDIEndpointRef) -> String {
    var value: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value)
    return value?.takeRetainedValue() as String? ?? "?"
}

func connectMatching() {
    for i in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(i)
        guard source != 0, !connected.contains(source), name(source).contains(match) else { continue }
        let context = UnsafeMutableRawPointer(bitPattern: Int(source))
        MIDIPortConnectSource(port, source, context)
        connected.insert(source)
        print("connected to \(name(source))")
        fflush(stdout)
    }
}

MIDIClientCreateWithBlock("midi-monitor" as CFString, &client) { _ in DispatchQueue.main.async { connectMatching() } }
MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { list, context in
    let source = MIDIEndpointRef(UInt32(truncatingIfNeeded: Int(bitPattern: context)))
    for packet in list.unsafeSequence() {
        let words = packet.words()
        for word in words where word >> 28 == 2 {  // MIDI 1.0 channel voice message
            let status = Int(word >> 16 & 0xFF), d1 = Int(word >> 8 & 0x7F), d2 = Int(word & 0x7F)
            let channel = (status & 0x0F) + 1
            let label: String
            switch status & 0xF0 {
            case 0xC0: label = "Program Change \(d1) ch \(channel)"
            case 0xB0: label = "Control Change \(d1) = \(d2) ch \(channel)"
            case 0x90: label = "Note On \(d1) ch \(channel)"
            default: label = String(format: "status %02X", status)
            }
            let time = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }()
            print("\(time) \(name(source)): \(label)")
            fflush(stdout)
        }
    }
}
connectMatching()
print("watching MIDI sources matching \"\(match)\"")
fflush(stdout)
RunLoop.main.run()
