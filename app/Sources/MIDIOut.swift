import CoreMIDI

/// A virtual MIDI source, "Rocksmith Companion". Apps that listen to every MIDI source see it
/// with no setup; it disappears when the app quits.
final class MIDIOut {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private(set) var error: String?

    init(name: String = "Rocksmith Companion") {
        var status = MIDIClientCreateWithBlock(name as CFString, &client, nil)
        if status == noErr { status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source) }
        if status != noErr { error = "MIDI unavailable (\(status))" }
    }

    /// Program Change on a channel (1-16).
    func programChange(_ program: Int, channel: Int) {
        send(0xC0 | UInt32((channel - 1) & 0x0F), program)
    }

    private func send(_ status: UInt32, _ data1: Int, _ data2: Int = 0) {
        guard error == nil else { return }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = 0x2000_0000 | status << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)  // MIDI 1.0 UMP
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, &list)
    }
}
