import Foundation

/// Tells rs-tonehost, the plug-in host of RS Re-ARMed's mods, how much too hot a song's tones are against its record: the AI's
/// gain_offset, which it can't know itself. It plays the game's knobs, and RS Companion knows the song.
enum ToneHost {
    static var commands: String {
        NSHomeDirectory() + "/Library/Application Support/RS Re-ARMed/tonehost/commands"
    }

    /// One line on the host's FIFO. Returns false, and never waits, if no host is listening.
    @discardableResult
    static func send(offset: Double, to path: String = commands) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return false }
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let line = Array(String(format: "offset %g\n", offset).utf8)
        return write(fd, line, line.count) == line.count
    }
}
