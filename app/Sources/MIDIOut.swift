import CoreMIDI

/// A virtual MIDI source, "Rocksmith Companion". Apps that listen to every MIDI source see it
/// with no setup; it disappears when the app quits.
final class MIDIOut {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private(set) var error: String?
    /// What was sent in the first `settle` after the source appeared, in order. A listener connects
    /// to a new source a moment after it appears, so a song already loaded when the app starts
    /// would otherwise send its tones to nobody.
    private var held: [() -> Void]? = []
    private static let settle: TimeInterval = 1

    init(name: String = "Rocksmith Companion") {
        var status = MIDIClientCreateWithBlock(name as CFString, &client, nil)
        if status == noErr { status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source) }
        if status != noErr { error = "MIDI unavailable (\(status))" }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            let held = self?.held ?? []
            self?.held = nil
            held.forEach { $0() }
        }
    }

    /// Runs `send` now, or once the source has settled.
    private func whenSettled(_ send: @escaping () -> Void) {
        if held != nil { held?.append(send) } else { send() }
    }

    /// Program Change on a channel (1-16).
    func programChange(_ program: Int, channel: Int) {
        send(0xC0 | UInt32((channel - 1) & 0x0F), program)
    }

    /// A System Exclusive message: `data` is what goes between F0 and F7 (7-bit bytes; the top
    /// bit is dropped). Sent as MIDI 1.0 UMP SysEx7 packets, 6 bytes each, in order.
    func sysex(_ data: [UInt8]) {
        guard error == nil else { return }
        whenSettled { self.sendSysex(data) }
    }

    private func sendSysex(_ data: [UInt8]) {
        let body = data.map { $0 & 0x7F }
        let chunks = stride(from: 0, to: max(body.count, 1), by: 6).map { Array(body[$0..<min($0 + 6, body.count)]) }
        let list = UnsafeMutablePointer<MIDIEventList>.allocate(capacity: 1)
        defer { list.deallocate() }
        // A list holds one packet of up to 64 words: 32 two-word SysEx7 messages per send.
        for start in stride(from: 0, to: chunks.count, by: 32) {
            var packet = MIDIEventListInit(list, ._1_0)
            for i in start..<min(start + 32, chunks.count) {
                let status: UInt32 = chunks.count == 1 ? 0 : i == 0 ? 1 : i == chunks.count - 1 ? 3 : 2  // complete, start, continue, end
                let b = (chunks[i] + [0, 0, 0, 0, 0, 0]).map(UInt32.init)
                var words: [UInt32] = [0x3000_0000 | status << 20 | UInt32(chunks[i].count) << 16 | b[0] << 8 | b[1],
                                       b[2] << 24 | b[3] << 16 | b[4] << 8 | b[5]]
                packet = MIDIEventListAdd(list, MemoryLayout<MIDIEventList>.size, packet, 0, 2, &words)
            }
            MIDIReceivedEventList(source, list)
        }
    }

    private func send(_ status: UInt32, _ data1: Int, _ data2: Int = 0) {
        guard error == nil else { return }
        whenSettled { self.sendShort(status, data1, data2) }
    }

    private func sendShort(_ status: UInt32, _ data1: Int, _ data2: Int) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = 0x2000_0000 | status << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)  // MIDI 1.0 UMP
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, &list)
    }
}
