// Prints MIDI messages from sources whose name contains a text (default "Rocksmith Companion"),
// one line each: time, source, bytes and a label (a SysEx message: its bytes as text). Connects to
// matching sources as they appear.
// Build: swiftc -O tools/midi_monitor.swift -o build/midi_monitor
// Usage: build/midi_monitor ["source name part"]
import CoreMIDI
import Foundation

let match = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Rocksmith Companion"
var client = MIDIClientRef()
var port = MIDIPortRef()
var connected = Set<MIDIEndpointRef>()
var sysex: [UInt8] = []  // the SysEx message being received

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
        let words = Array(packet.words())
        var w = 0
        while w < words.count {  // one UMP message at a time: its type says how many words it has
            let word = words[w]
            let time = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }()
            switch word >> 28 {
            case 3 where w + 1 < words.count:  // SysEx7: two words, up to 6 bytes
                let status = word >> 20 & 0xF, n = Int(word >> 16 & 0xF)
                let bytes = [word >> 8, word, words[w + 1] >> 24, words[w + 1] >> 16, words[w + 1] >> 8, words[w + 1]]
                if status <= 1 { sysex = [] }
                sysex += bytes.prefix(n).map { UInt8($0 & 0x7F) }
                if status == 0 || status == 3 {
                    print("\(time) \(name(source)): SysEx \(sysex.count) bytes: " + String(decoding: sysex, as: UTF8.self))
                    fflush(stdout)
                }
                w += 2
            case 2:  // MIDI 1.0 channel voice message
                let status = Int(word >> 16 & 0xFF), d1 = Int(word >> 8 & 0x7F), d2 = Int(word & 0x7F)
                let channel = (status & 0x0F) + 1
                let label: String
                switch status & 0xF0 {
                case 0xC0: label = "Program Change \(d1) ch \(channel)"
                case 0xB0: label = "Control Change \(d1) = \(d2) ch \(channel)"
                case 0x90: label = "Note On \(d1) ch \(channel)"
                default: label = String(format: "status %02X", status)
                }
                print("\(time) \(name(source)): \(label)")
                fflush(stdout)
                w += 1
            default:
                w += 1
            }
        }
    }
}
connectMatching()
print("watching MIDI sources matching \"\(match)\"")
fflush(stdout)
RunLoop.main.run()
