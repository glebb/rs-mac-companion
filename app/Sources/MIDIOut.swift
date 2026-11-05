import CoreMIDI

/// Sends a profile's steps (Profile.swift), in order: from the virtual MIDI source "Rocksmith
/// Companion", which apps that listen to every MIDI source see with no setup and which disappears
/// when the app quits, or straight to a MIDI destination by name.
final class MIDIOut {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var port = MIDIPortRef()
    private(set) var error: String?
    private var queue: [(step: Profile.Step, channel: Int, destination: Profile.Destination, message: [UInt8]?)] = []
    /// Nothing goes out for now. At first: a listener connects to a new source a moment after it
    /// appears, so a song already loaded when the app starts would otherwise send its tones to
    /// nobody. After that: during a wait step.
    private var holding = true
    private static let settle: TimeInterval = 1

    init(name: String = "Rocksmith Companion") {
        var status = MIDIClientCreateWithBlock(name as CFString, &client, nil)
        if status == noErr { status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source) }
        if status == noErr { status = MIDIOutputPortCreate(client, "out" as CFString, &port) }
        if status != noErr { error = "MIDI unavailable (\(status))" }
        hold(for: Self.settle)
    }

    private func hold(for seconds: TimeInterval) {
        holding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.holding = false
            self?.drain()
        }
    }

    /// Whether something can be sent there now.
    func reachable(_ destination: Profile.Destination) -> Bool {
        guard error == nil else { return false }
        if case .device(let name) = destination { return endpoint(named: name) != nil }
        return true
    }

    /// Queues the steps after anything still waiting. `message` is what a song tones step sends:
    /// what goes between F0 and F7. Returns false, sending nothing, if the destination isn't there.
    @discardableResult
    func play(_ steps: [Profile.Step], channel: Int, to destination: Profile.Destination, message: [UInt8]? = nil) -> Bool {
        guard reachable(destination) else { return false }
        queue += steps.map { ($0, channel, destination, message) }
        drain()
        return true
    }

    private func drain() {
        while !holding, !queue.isEmpty {
            let (step, channel, destination, message) = queue.removeFirst()
            let voice = UInt32((channel - 1) & 0x0F)
            switch step {
            case .pc(let program): sendShort(0xC0 | voice, program, 0, to: destination)
            case .cc(let number, let value): sendShort(0xB0 | voice, number, value, to: destination)
            case .wait(let ms): hold(for: Double(ms) / 1000)
            case .bytes(let bytes) where bytes[0] == 0xF0: sendSysex(Array(bytes.dropFirst().dropLast()), to: destination)
            case .bytes(let bytes):
                sendShort(UInt32(bytes[0]), Int(bytes[1]), bytes.count > 2 ? Int(bytes[2]) : 0, to: destination)
            case .songTonesMessage:
                if let message { sendSysex(message, to: destination) }
            }
        }
    }

    private func endpoint(named name: String) -> MIDIEndpointRef? {
        (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination).first { endpoint in
            var value: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value)
            return value?.takeRetainedValue() as String? == name
        }
    }

    private func deliver(_ list: UnsafePointer<MIDIEventList>, to destination: Profile.Destination) {
        switch destination {
        case .virtual: MIDIReceivedEventList(source, list)
        case .device(let name):
            if let endpoint = endpoint(named: name) { MIDISendEventList(port, endpoint, list) }
        }
    }

    /// A System Exclusive message: `data` is what goes between F0 and F7 (7-bit bytes; the top
    /// bit is dropped). Sent as MIDI 1.0 UMP SysEx7 packets, 6 bytes each, in order.
    private func sendSysex(_ data: [UInt8], to destination: Profile.Destination) {
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
            deliver(list, to: destination)
        }
    }

    private func sendShort(_ status: UInt32, _ data1: Int, _ data2: Int, to destination: Profile.Destination) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = 0x2000_0000 | status << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)  // MIDI 1.0 UMP
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        deliver(&list, to: destination)
    }
}
