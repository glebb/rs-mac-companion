import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A song's details in RockSniffer's "songDetails" shape (RockSnifferLib's SongDetails,
/// ArrangementDetails, ArrangementTuning and ArrangementData, MIT), read from the song's archive
/// with native/rsfile.c: manifests, album art and the .sng files. JSON-ready ([String: Any]).
enum SongDetails {
    /// The details of the song whose arrangement files start with `prefix` (e.g. "selftrap" for
    /// "selftrap_bass"), and each manifest's PersistentID by arrangement name (lower case), or
    /// nil if the archive can't be read.
    static func read(archive: String, prefix: String) -> (details: [String: Any], ids: [String: String])? {
        guard let p = rs_psarc_open(archive) else { return nil }
        defer { rs_psarc_close(p) }
        let entries = (0..<Int(p.pointee.n)).map { String(cString: p.pointee.e[$0].path) }

        func read(_ path: String) -> Data? {
            guard let e = rs_psarc_find(p, path) else { return nil }
            var len = 0
            guard let bytes = rs_psarc_read(p, e, &len) else { return nil }
            defer { free(bytes) }
            return Data(bytes: bytes, count: len)
        }

        /// The plain (decrypted, unpacked) .sng of an arrangement.
        func sng(_ name: String) -> Data? {
            guard let raw = read("songs/bin/macos/\(name).sng") else { return nil }
            return raw.withUnsafeBytes { buf -> Data? in
                var plen = 0
                guard let base = buf.bindMemory(to: UInt8.self).baseAddress,
                      let d = rs_sng_plain(base, raw.count, &plen) else { return nil }
                defer { free(d) }
                return Data(bytes: d, count: plen)
            }
        }

        let manifests = entries.filter {
            $0.hasPrefix("manifests/") && $0.hasSuffix(".json")
                && ($0 as NSString).lastPathComponent.lowercased().hasPrefix(prefix.lowercased() + "_")
        }
        var details: [String: Any] = ["vocals": [Any](), "arrangements": [Any](), "songLength": 0, "albumYear": 0]
        var arrangements: [[String: Any]] = []
        var ids: [String: String] = [:]
        var albumArt: String?
        for path in manifests.sorted() {
            guard let data = read(path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = (json["Entries"] as? [String: Any])?.values.first as? [String: Any],
                  let a = entry["Attributes"] as? [String: Any] else { continue }
            let name = ((a["SongXml"] as? String)?.components(separatedBy: ":").last ?? "").lowercased()
            if let id = a["PersistentID"] as? String, !name.isEmpty { ids[name] = id }
            if a["ArrangementName"] as? String == "Vocals" {
                if (details["vocals"] as? [Any])?.isEmpty ?? true, let plain = sng(name) {
                    details["vocals"] = vocals(plain)
                }
                continue
            }
            guard a["Phrases"] != nil else { continue }
            if albumArt == nil, let urn = a["AlbumArt"] as? String, let art = urn.components(separatedBy: ":").last {
                albumArt = jpegBase64(read("gfxassets/album_art/\(art)_256.dds"))
            }
            let props = a["ArrangementProperties"] as? [String: Any] ?? [:]
            func prop(_ k: String) -> Int { (props[k] as? NSNumber)?.intValue ?? 0 }
            var arr: [String: Any] = [
                "name": a["ArrangementName"] as? String ?? "",
                "arrangementID": a["PersistentID"] as? String ?? "",
                "type": (prop("pathLead") == 1 ? "Lead" : prop("pathRhythm") == 1 ? "Rhythm"
                    : prop("pathBass") == 1 ? "Bass" : nil) as Any? ?? NSNull(),
                "isBonusArrangement": prop("bonusArr") == 1,
                "isAlternateArrangement": prop("represent") == 0,
                "tuning": tuning(a),
                "sections": numbered(a["Sections"]) { s, label in
                    ["name": label, "startTime": s["StartTime"] ?? 0, "endTime": s["EndTime"] ?? 0]
                },
                "phraseIterations": numbered(a["PhraseIterations"]) { s, label in
                    ["name": label, "phraseId": s["PhraseIndex"] ?? 0, "maxDifficulty": s["MaxDifficulty"] ?? 0,
                     "startTime": s["StartTime"] ?? 0, "endTime": s["EndTime"] ?? 0]
                },
                "data": ["Measures": sng(name).map(measures) ?? []],
            ]
            if arr["arrangementID"] as? String == "" { arr["arrangementID"] = NSNull() }
            arrangements.append(arr)
            details["songID"] = a["SongKey"]
            details["songLength"] = a["SongLength"] ?? 0
            details["songName"] = a["SongName"]
            details["artistName"] = a["ArtistName"]
            details["albumName"] = a["AlbumName"]
            details["albumYear"] = a["SongYear"] ?? 0
        }
        details["arrangements"] = arrangements
        details["NumArrangements"] = arrangements.count
        details["toolkit"] = toolkit(read("toolkit.version"))
        details["albumArt"] = albumArt ?? NSNull()
        details["psarcFileHash"] = fileHash(archive) ?? NSNull()
        return (details, ids)
    }

    /// RockSniffer names sections and phrase iterations "<Name> <n>", n counting each name.
    private static func numbered(_ list: Any?, _ make: ([String: Any], String) -> [String: Any]) -> [[String: Any]] {
        var counts: [String: Int] = [:]
        return (list as? [[String: Any]] ?? []).map { s in
            let name = s["Name"] as? String ?? ""
            counts[name, default: 0] += 1
            return make(s, "\(name) \(counts[name]!)")
        }
    }

    // MARK: .sng arrays (docs/song-files.md)

    private struct Reader {
        let d: Data
        var at = 0
        func i32(_ o: Int) -> Int32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) } }
        func i16(_ o: Int) -> Int16 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int16.self) } }
        func f32(_ o: Int) -> Float { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Float.self) } }
        /// The next array: its record count and where its records start, or nil past the end.
        mutating func array(_ size: Int) -> (count: Int, start: Int)? {
            guard at + 4 <= d.count else { return nil }
            let n = Int(i32(at))
            guard n >= 0, at + 4 + n * size <= d.count else { return nil }
            defer { at += 4 + n * size }
            return (n, at + 4)
        }
    }

    /// Measure starts from the beats array (16 bytes: f32 time, i16 measure, ...), as
    /// RockSniffer's ArrangementData: the first beat, then every beat whose measure differs.
    private static func measures(_ plain: Data) -> [[String: Any]] {
        var r = Reader(d: plain)
        guard let (n, start) = r.array(16) else { return [] }
        var out: [[String: Any]] = []
        var last: Int16?
        for i in 0..<n {
            let o = start + i * 16
            let measure = r.i16(o + 4)
            if last == nil || measure != last {
                out.append(["Time": Double(r.f32(o)), "Number": Int(measure)])
                last = measure
            }
        }
        return out
    }

    /// Lyrics from the vocals array (5th; 60 bytes: f32 time, i32 note, f32 length, char[48] lyric).
    private static func vocals(_ plain: Data) -> [[String: Any]] {
        var r = Reader(d: plain)
        for size in [16, 44, 72, 2376] { guard r.array(size) != nil else { return [] } }
        guard let (n, start) = r.array(60) else { return [] }
        return (0..<n).map { i in
            let o = start + i * 60
            let text = plain[(plain.startIndex + o + 12)..<(plain.startIndex + o + 60)]
            let lyric = String(decoding: text.prefix { $0 != 0 }, as: UTF8.self)
            return ["Time": Double(r.f32(o)), "Note": Int(r.i32(o + 4)), "Length": Double(r.f32(o + 8)), "Lyric": lyric]
        }
    }

    // MARK: Other parts

    /// toolkit.version of custom songs: "Toolkit version: ...", "Package Author: ...", ...
    /// RockSniffer reports the package version as "version" too.
    private static func toolkit(_ data: Data?) -> [String: Any] {
        var fields: [String: String] = [:]
        for line in String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let version: Any = fields["package version"] ?? NSNull()
        return ["version": version, "author": fields["package author"] ?? NSNull(),
                "package_version": version, "comment": fields["package comment"] ?? NSNull()]
    }

    /// Album art (DDS, which ImageIO reads) as base64 JPEG, as RockSniffer sends it.
    static func jpegBase64(_ dds: Data?) -> String? {
        guard let dds, let src = CGImageSourceCreateWithData(dds as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }

    /// Base64 MD5 of the whole archive, as RockSniffer's psarcFileHash.
    private static func fileHash(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var md5 = Insecure.MD5()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { md5.update(data: chunk) }
        return Data(md5.finalize()).base64EncodedString()
    }

    // MARK: Tuning (RockSniffer's ArrangementTuning)

    private static func tuning(_ a: [String: Any]) -> [String: Any] {
        let t = a["Tuning"] as? [String: Any] ?? [:]
        let strings = (0..<6).map { (t["string\($0)"] as? NSNumber)?.intValue ?? 0 }
        let cents = (a["CentOffset"] as? NSNumber)?.intValue ?? 0
        let capo = (a["CapoFret"] as? NSNumber)?.intValue ?? 0
        var name = tunings.first { $0.strings == strings }?.name ?? "Custom Tuning"
        for p in ["1G-", "2G-", "3G-", "1B-", "2B-", "3B-"] { name = name.replacingOccurrences(of: p, with: "") }
        if cents != 0 { name += ": A\(Int(floor(440 * pow(2, Double(cents) / 1200))))" }
        if capo != 0 { name += " (Capo Fret \(capo))" }
        var out: [String: Any] = ["CentsOffset": cents, "CapoFret": capo, "TuningName": name]
        for (i, s) in strings.enumerated() { out["String\(i)"] = s }
        return out
    }

    /// Offsets of strings 0-5 by name, first match wins (RockSniffer's table).
    private static let tunings: [(name: String, strings: [Int])] = [
        ("3G-E Standard", [12, 12, 12, 12, 12, 12]),
        ("2G-Eb Standard", [11, 11, 11, 11, 11, 11]),
        ("2G-D Standard", [10, 10, 10, 10, 10, 10]),
        ("2G-C# Standard", [9, 9, 9, 9, 9, 9]),
        ("2G-C Standard", [8, 8, 8, 8, 8, 8]),
        ("2G-B Standard", [7, 7, 7, 7, 7, 7]),
        ("2G-Bb Standard", [6, 6, 6, 6, 6, 6]),
        ("2G-A Standard", [5, 5, 5, 5, 5, 5]),
        ("2G-Ab Standard", [4, 4, 4, 4, 4, 4]),
        ("2G-G Standard", [3, 3, 3, 3, 3, 3]),
        ("2G-F# Standard", [2, 2, 2, 2, 2, 2]),
        ("2G-F Standard", [1, 1, 1, 1, 1, 1]),
        ("2G-E Standard", [0, 0, 0, 0, 0, 0]),
        ("1G-Eb Standard", [-1, -1, -1, -1, -1, -1]),
        ("1G-D Standard", [-2, -2, -2, -2, -2, -2]),
        ("1G-C# Standard", [-3, -3, -3, -3, -3, -3]),
        ("1G-C Standard", [-4, -4, -4, -4, -4, -4]),
        ("1G-B Standard", [-5, -5, -5, -5, -5, -5]),
        ("1G-Bb Standard", [-6, -6, -6, -6, -6, -6]),
        ("1G-A Standard", [-7, -7, -7, -7, -7, -7]),
        ("1G-Ab Standard", [-8, -8, -8, -8, -8, -8]),
        ("1G-G Standard", [-9, -9, -9, -9, -9, -9]),
        ("1G-F# Standard", [-10, -10, -10, -10, -10, -10]),
        ("1G-F Standard", [-11, -11, -11, -11, -11, -11]),
        ("1G-E Standard", [-12, -12, -12, -12, -12, -12]),
        ("3B-E Standard", [12, 12, 12, 12, 0, 0]),
        ("2B-Eb Standard", [11, 11, 11, 11, 0, 0]),
        ("2B-D Standard", [10, 10, 10, 10, 0, 0]),
        ("2B-C# Standard", [9, 9, 9, 9, 0, 0]),
        ("2B-C Standard", [8, 8, 8, 8, 0, 0]),
        ("2B-B Standard", [7, 7, 7, 7, 0, 0]),
        ("2B-Bb Standard", [6, 6, 6, 6, 0, 0]),
        ("2B-A Standard", [5, 5, 5, 5, 0, 0]),
        ("2B-Ab Standard", [4, 4, 4, 4, 0, 0]),
        ("2B-G Standard", [3, 3, 3, 3, 0, 0]),
        ("2B-F# Standard", [2, 2, 2, 2, 0, 0]),
        ("2B-F Standard", [1, 1, 1, 1, 0, 0]),
        ("1B-Eb Standard", [-1, -1, -1, -1, 0, 0]),
        ("1B-D Standard", [-2, -2, -2, -2, 0, 0]),
        ("1B-C# Standard", [-3, -3, -3, -3, 0, 0]),
        ("1B-C Standard", [-4, -4, -4, -4, 0, 0]),
        ("1B-B Standard", [-5, -5, -5, -5, 0, 0]),
        ("1B-Bb Standard", [-6, -6, -6, -6, 0, 0]),
        ("1B-A Standard", [-7, -7, -7, -7, 0, 0]),
        ("1B-Ab Standard", [-8, -8, -8, -8, 0, 0]),
        ("1B-G Standard", [-9, -9, -9, -9, 0, 0]),
        ("1B-F# Standard", [-10, -10, -10, -10, 0, 0]),
        ("1B-F Standard", [-11, -11, -11, -11, 0, 0]),
        ("1B-E Standard", [-12, -12, -12, -12, 0, 0]),
        ("3G-F# Drop E", [12, 14, 14, 14, 14, 14]),
        ("3G-F Drop Eb", [11, 13, 13, 13, 13, 13]),
        ("3G-Drop D", [10, 12, 12, 12, 12, 12]),
        ("2G-Eb Drop Db", [9, 11, 11, 11, 11, 11]),
        ("2G-D Drop C", [8, 10, 10, 10, 10, 10]),
        ("2G-C# Drop B", [7, 9, 9, 9, 9, 9]),
        ("2G-C Drop Bb", [6, 8, 8, 8, 8, 8]),
        ("2G-B Drop A", [5, 7, 7, 7, 7, 7]),
        ("2G-Bb Drop Ab", [4, 6, 6, 6, 6, 6]),
        ("2G-A Drop G", [3, 5, 5, 5, 5, 5]),
        ("2G-Ab Drop F#", [2, 4, 4, 4, 4, 4]),
        ("2G-G Drop F", [1, 3, 3, 3, 3, 3]),
        ("2G-F# Drop E", [0, 2, 2, 2, 2, 2]),
        ("2G-F Drop Eb", [-1, 1, 1, 1, 1, 1]),
        ("2G-Drop D", [-2, 0, 0, 0, 0, 0]),
        ("1G-Eb Drop Db", [-3, -1, -1, -1, -1, -1]),
        ("1G-D Drop C", [-4, -2, -2, -2, -2, -2]),
        ("1G-C# Drop B", [-5, -3, -3, -3, -3, -3]),
        ("1G-C Drop Bb", [-6, -4, -4, -4, -4, -4]),
        ("1G-B Drop A", [-7, -5, -5, -5, -5, -5]),
        ("1G-Bb Drop Ab", [-8, -6, -6, -6, -6, -6]),
        ("1G-A Drop G", [-9, -7, -7, -7, -7, -7]),
        ("1G-Ab Drop F#", [-10, -8, -8, -8, -8, -8]),
        ("1G-G Drop F", [-11, -9, -9, -9, -9, -9]),
        ("1G-F# Drop E", [-12, -10, -10, -10, -10, -10]),
        ("1G-F Drop Eb", [-13, -11, -11, -11, -11, -11]),
        ("1G-Drop D", [-14, -12, -12, -12, -12, -12]),
        ("3B-F# Drop E", [12, 14, 14, 14, 0, 0]),
        ("3B-F Drop Eb", [11, 13, 13, 13, 0, 0]),
        ("3B-Drop D", [10, 12, 12, 12, 0, 0]),
        ("2B-Eb Drop Db", [9, 11, 11, 11, 0, 0]),
        ("2B-D Drop C", [8, 10, 10, 10, 0, 0]),
        ("2B-C# Drop B", [7, 9, 9, 9, 0, 0]),
        ("2B-C Drop Bb", [6, 8, 8, 8, 0, 0]),
        ("2B-B Drop A", [5, 7, 7, 7, 0, 0]),
        ("2B-Bb Drop Ab", [4, 6, 6, 6, 0, 0]),
        ("2B-A Drop G", [3, 5, 5, 5, 0, 0]),
        ("2B-Ab Drop F#", [2, 4, 4, 4, 0, 0]),
        ("2B-G Drop F", [1, 3, 3, 3, 0, 0]),
        ("2B-F# Drop E", [0, 2, 2, 2, 0, 0]),
        ("2B-F Drop Eb", [-1, 1, 1, 1, 0, 0]),
        ("2B-Drop D", [-2, 0, 0, 0, 0, 0]),
        ("1B-Eb Drop Db", [-3, -1, -1, -1, 0, 0]),
        ("1B-D Drop C", [-4, -2, -2, -2, 0, 0]),
        ("1B-C# Drop B", [-5, -3, -3, -3, 0, 0]),
        ("1B-C Drop Bb", [-6, -4, -4, -4, 0, 0]),
        ("1B-B Drop A", [-7, -5, -5, -5, 0, 0]),
        ("1B-Bb Drop Ab", [-8, -6, -6, -6, 0, 0]),
        ("1B-A Drop G", [-9, -7, -7, -7, 0, 0]),
        ("1B-Ab Drop F#", [-10, -8, -8, -8, 0, 0]),
        ("1B-G Drop F", [-11, -9, -9, -9, 0, 0]),
        ("1B-F# Drop E", [-12, -10, -10, -10, 0, 0]),
        ("1B-F Drop Eb", [-13, -11, -11, -11, 0, 0]),
        ("1B-Drop D", [-14, -12, -12, -12, 0, 0]),
        ("Open A", [0, 0, 2, 2, 2, 0]),
        ("Open B", [-5, -3, -3, -1, 0, -1]),
        ("Open C", [-4, -2, -2, 0, 1, 0]),
        ("Open D", [-2, 0, 0, -1, -2, -2]),
        ("Open E", [0, 2, 2, 1, 0, 0]),
        ("Open F", [-4, -4, -2, -2, -2, 1]),
        ("Open G", [-2, -2, 0, 0, 0, -2]),
        ("DADGAD", [-2, 0, 0, 0, -2, -2]),
        ("Minor Third", [-4, -6, -8, -10, -11, -13]),
        ("Major Third", [-8, -9, -10, -11, -11, -12]),
        ("Fourths", [0, 0, 0, 0, 1, 1]),
        ("Aug Fourths", [-4, -3, -2, -1, 1, 2]),
        ("Fifths", [-4, -2, 0, 2, 5, 7]),
        ("Double Drop D", [-2, 0, 0, 0, 0, -2]),
        ("Nick Drake", [-4, -2, -2, -2, 1, 0]),
        ("C6 Modal", [-4, 0, -2, 0, 1, 0]),
    ]
}
