import Foundation

/// Adds and removes LC_LOAD_DYLIB load commands in the x86_64 slice of a (universal) Mach-O
/// executable, in memory. Same rules as tools/add_load_dylib.py:
///  - a command is added after the existing ones, in the header padding before the first section,
///    so nothing else moves; the padding must be zero-filled;
///  - removing shifts the commands after it up and zero-fills the freed tail, so adding and then
///    removing a command gives back the original bytes. Library ordinals of later LC_LOAD_DYLIBs
///    shift by one: harmless for libraries the program imports nothing from (ours, and the
///    custom-song patch's libRSBypass, which are always after the game's own libraries).
struct MachOPatcher {
    enum Failure: Error, CustomStringConvertible {
        case notMachO, noX86Slice, noSpace(free: Int, need: Int), paddingNotEmpty
        var description: String {
            switch self {
            case .notMachO: "not a Mach-O executable"
            case .noX86Slice: "no x86_64 code in the executable"
            case let .noSpace(free, need): "not enough header space (\(free) bytes free, \(need) needed)"
            case .paddingNotEmpty: "the executable's header padding is not empty"
            }
        }
    }

    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let machO64: UInt32 = 0xFEED_FACF
    private static let x86_64: Int32 = 0x0100_0007
    private static let lcLoadDylib: UInt32 = 0xC
    private static let lcSegment64: UInt32 = 0x19

    var data: Data
    private let base: Int  // offset of the x86_64 slice

    init(_ data: Data) throws {
        self.data = data
        func be32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        guard data.count >= 32 else { throw Failure.notMachO }
        if be32(0) == Self.fatMagic {
            // fat_arch entries are 20 bytes after the 8-byte header; all of them must be in the file.
            let count = Int(be32(4))
            guard 8 + count * 20 <= data.count else { throw Failure.notMachO }
            var found: Int?
            for i in 0..<count where Int32(bitPattern: be32(8 + i * 20)) == Self.x86_64 {
                found = Int(be32(8 + i * 20 + 8))
            }
            guard let found else { throw Failure.noX86Slice }
            base = found
        } else {
            base = 0
        }
        guard base >= 0, base + 32 <= data.count, u32(base) == Self.machO64, Int32(bitPattern: u32(base + 4)) == Self.x86_64 else {
            throw Failure.notMachO
        }
        try validate()
    }

    /// Every load command must lie inside the declared commands and the file, so the readers
    /// below never index outside the data (a damaged file is an error, not a crash).
    private func validate() throws {
        let end = base + 32 + sizeofcmds
        guard sizeofcmds >= 0, end <= data.count else { throw Failure.notMachO }
        var off = base + 32
        for _ in 0..<ncmds {
            guard off + 8 <= end else { throw Failure.notMachO }
            let cmd = u32(off), size = Int(u32(off + 4))
            guard size >= 8, off + size <= end else { throw Failure.notMachO }
            if cmd == Self.lcLoadDylib {
                guard size >= 24, Int(u32(off + 8)) < size else { throw Failure.notMachO }
            }
            if cmd == Self.lcSegment64 {
                guard size >= 72, 72 + Int(u32(off + 64)) * 80 <= size else { throw Failure.notMachO }
            }
            off += size
        }
    }

    // Little-endian fields of the x86_64 slice.
    private func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
    private mutating func put32(_ o: Int, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { data.replaceSubrange(o..<o + 4, with: $0) }
    }

    private var ncmds: Int { Int(u32(base + 16)) }
    private var sizeofcmds: Int { Int(u32(base + 20)) }

    /// (offset, size, path) of every LC_LOAD_DYLIB, in order.
    private func dylibCommands() -> [(offset: Int, size: Int, path: String)] {
        var out: [(Int, Int, String)] = []
        var off = base + 32
        for _ in 0..<ncmds {
            let cmd = u32(off), size = Int(u32(off + 4))
            if cmd == Self.lcLoadDylib {
                let nameOff = Int(u32(off + 8))
                let bytes = data[(off + nameOff)..<(off + size)].prefix { $0 != 0 }
                out.append((off, size, String(decoding: bytes, as: UTF8.self)))
            }
            off += size
        }
        return out
    }

    /// Paths of the libraries the executable loads.
    var dylibs: [String] { dylibCommands().map(\.path) }

    /// Offset (in the slice) where section data starts: the end of the free header space.
    private func firstSectionOffset() -> Int? {
        var first: Int?
        var off = base + 32
        for _ in 0..<ncmds {
            let cmd = u32(off), size = Int(u32(off + 4))
            if cmd == Self.lcSegment64 {
                for s in 0..<Int(u32(off + 64)) {
                    let sectOffset = Int(u32(off + 72 + s * 80 + 48))
                    if sectOffset > 0 { first = min(first ?? sectOffset, sectOffset) }
                }
            }
            off += size
        }
        return first
    }

    mutating func addDylib(_ path: String) throws {
        if dylibs.contains(path) { return }
        let name = Array(path.utf8) + [0]
        let cmdsize = (24 + name.count + 7) & ~7
        let end = 32 + sizeofcmds
        guard let first = firstSectionOffset(), end + cmdsize <= first else {
            throw Failure.noSpace(free: (firstSectionOffset() ?? end) - end, need: cmdsize)
        }
        guard data[(base + end)..<(base + end + cmdsize)].allSatisfy({ $0 == 0 }) else { throw Failure.paddingNotEmpty }
        // dylib_command: cmd, cmdsize, name offset, timestamp, current version, compatibility version
        var cmd = Data()
        for v: UInt32 in [Self.lcLoadDylib, UInt32(cmdsize), 24, 2, 0, 0] { withUnsafeBytes(of: v.littleEndian) { cmd.append(contentsOf: $0) } }
        cmd.append(contentsOf: name)
        cmd.append(contentsOf: [UInt8](repeating: 0, count: cmdsize - cmd.count))
        data.replaceSubrange((base + end)..<(base + end + cmdsize), with: cmd)
        let n = ncmds, s = sizeofcmds
        put32(base + 16, UInt32(n + 1))
        put32(base + 20, UInt32(s + cmdsize))
    }

    /// Removes every LC_LOAD_DYLIB whose path matches. Returns how many were removed.
    @discardableResult
    mutating func removeDylibs(where matches: (String) -> Bool) -> Int {
        var removed = 0
        while let c = dylibCommands().first(where: { matches($0.path) }) {
            let end = base + 32 + sizeofcmds
            let after = data[(c.offset + c.size)..<end]
            data.replaceSubrange(c.offset..<(c.offset + after.count), with: after)
            data.replaceSubrange((end - c.size)..<end, with: Data(count: c.size))
            let n = ncmds, s = sizeofcmds
            put32(base + 16, UInt32(n - 1))
            put32(base + 20, UInt32(s - c.size))
            removed += 1
        }
        return removed
    }
}
