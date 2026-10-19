import Foundation

/// One event from the in-game dylib (native/rscompanion.c, see its "events" section).
struct GameEvent: Decodable {
    struct Tone: Decodable, Equatable {
        let slot: String
        let tone: String
        let descriptors: [String]
    }

    /// An arrangement of the song with its tone slots (slot name -> tone key).
    struct Part: Decodable, Equatable {
        let arrangement: String
        let slots: [String: String]
    }

    let event: String              // "song", "tone" or "state"
    let song: String?
    let artist: String?
    let arrangement: String?
    let tones: [Tone]?             // song, state: the arrangement's tone slots in use
    let parts: [Part]?             // song, state: every arrangement of the song
    let slot: String?              // tone, state: the active slot (Base, A-D)
    let tone: String?              // tone, state: the active tone key
    let descriptors: [String]?     // tone: its tags
    let source: String?            // tone: song-start, banner or timer
    let time: Double?              // song time in seconds, if known
    let timer_locked: Bool?        // state
    let lead_ms: Int?              // state
    let pid: Int?                  // state
}

/// Owns the Unix datagram socket the dylib sends to (DATA_DIR/events.sock) and decodes what
/// arrives. Events are delivered on the main queue.
final class EventSocket {
    let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "rs-companion.events")
    private let onEvent: (GameEvent) -> Void

    init(path: String, onEvent: @escaping (GameEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    /// Returns an error message, or nil when listening.
    func start() -> String? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return "socket path too long: \(path)" }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        unlink(path)  // left over from an app that did not quit cleanly
        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "socket: \(String(cString: strerror(errno)))" }
        var size: Int32 = 1 << 18
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { return "bind \(path): \(String(cString: strerror(errno)))" }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        self.source = source
        return nil
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(path)
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return }
            let data = Data(buffer[0..<n])
            guard let event = try? JSONDecoder().decode(GameEvent.self, from: data) else { continue }
            DispatchQueue.main.async { self.onEvent(event) }
        }
    }
}
