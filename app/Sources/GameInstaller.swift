import AppKit
import Foundation

/// Installs the companion into Rocksmith: adds a load command for librscompanion.dylib to the
/// game executable and puts the dylib (bundled in this app) next to it. Also updates it, removes
/// it, and tells which state the game is in.
struct GameInstaller {
    static let defaultGameDir = NSHomeDirectory() + "/Library/Application Support/Steam/steamapps/common/Rocksmith2014"
    static let steamAppID = "221680"
    static let dylibName = "librscompanion.dylib"
    static let loadPath = "@executable_path/" + dylibName
    /// Earlier names of the companion library (prototype installs), replaced on install.
    static let oldNames = ["librscompanion_test.dylib"]

    enum Status: Equatable {
        case gameNotFound
        case notInstalled             // never installed, or Steam replaced the executable
        case updateAvailable          // installed, but an older library (or name)
        case installed
        case problem(String)

        var summary: String {
            switch self {
            case .gameNotFound: "Rocksmith not found"
            case .notInstalled: "Not installed in Rocksmith"
            case .updateAvailable: "Installed; an update is available"
            case .installed: "Installed in Rocksmith"
            case let .problem(text): text
            }
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case gameNotFound(String), gameRunning, noBundledLibrary, failed(String)
        var description: String {
            switch self {
            case let .gameNotFound(dir): "Rocksmith not found in \(dir)"
            case .gameRunning: "Quit Rocksmith first."
            case .noBundledLibrary: "This app does not contain the Rocksmith library (build it with app/build.sh)."
            case let .failed(text): text
            }
        }
    }

    // MARK: Finding the game

    private static var found: String?

    /// Where Steam installed the game: every Steam library (libraries on drives that aren't
    /// connected are skipped), then /Applications. Steam's default folder if it's nowhere.
    /// Remembered until that folder goes away.
    static func steamGameDir() -> String {
        if let found, isGameDir(found) { return found }
        found = findGame()
        return found ?? defaultGameDir
    }

    static func isGameDir(_ dir: String) -> Bool {
        FileManager.default.fileExists(atPath: dir + "/Rocksmith2014.app/Contents/MacOS/Rocksmith2014")
    }

    /// The game folder for a path the user picked: the folder itself, Rocksmith2014.app or
    /// anything inside the app. Nil if it isn't the game.
    static func gameDir(for path: String) -> String? {
        var dir = path
        if let range = dir.range(of: "/Rocksmith2014.app") { dir = String(dir[..<range.lowerBound]) }
        return isGameDir(dir) ? dir : nil
    }

    private static func findGame() -> String? {
        let steam = ProcessInfo.processInfo.environment["RS_STEAM_DIR"]  // for the tests
            ?? NSHomeDirectory() + "/Library/Application Support/Steam"
        var libraries = [steam]
        for list in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            if let text = try? String(contentsOfFile: steam + "/" + list, encoding: .utf8) {
                libraries += vdfValues("path", in: text)
            }
        }
        for library in libraries {
            // The folder is named in the game's manifest (normally Rocksmith2014).
            let manifest = try? String(contentsOfFile: library + "/steamapps/appmanifest_\(steamAppID).acf", encoding: .utf8)
            let names = (manifest.map { vdfValues("installdir", in: $0) } ?? []) + ["Rocksmith2014"]
            if let dir = names.map({ library + "/steamapps/common/" + $0 }).first(where: isGameDir) { return dir }
        }
        return ["/Applications/Rocksmith2014", "/Applications/Rocksmith 2014", NSHomeDirectory() + "/Applications/Rocksmith2014"]
            .first(where: isGameDir)
    }

    /// The values of every  "key"  "value"  line in a Steam .vdf/.acf file, unescaped.
    private static func vdfValues(_ key: String, in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count >= 5, parts[1] == key else { return nil }
            // Rejoin the value (between the 3rd and the last quote) and undo backslash escapes.
            let raw = parts[3 ..< parts.count - 1].joined(separator: "\"")
            return raw.replacingOccurrences(of: "\\\\", with: "\\")
        }
    }

    let gameDir: String
    let bundledDylib: URL?

    var macOSDir: String { gameDir + "/Rocksmith2014.app/Contents/MacOS" }
    var executable: String { macOSDir + "/Rocksmith2014" }
    var installedDylib: String { macOSDir + "/" + Self.dylibName }
    var backup: String { executable + ".orig" }

    static func isOurs(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == dylibName || oldNames.contains(name)
    }

    /// This game folder's Rocksmith is running. (Files are replaced by renaming, so even a game
    /// running from here would keep its loaded copies; the check is for a clear message.)
    var gameRunning: Bool {
        let target = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains {
            $0.executableURL?.resolvingSymlinksInPath().path == target
        }
    }

    func status() -> Status {
        guard FileManager.default.fileExists(atPath: executable) else { return .gameNotFound }
        let patcher: MachOPatcher
        do {
            patcher = try MachOPatcher(Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe))
        } catch {
            return .problem("Cannot read the game executable: \(error)")
        }
        let ours = patcher.dylibs.filter(Self.isOurs)
        if ours.isEmpty { return .notInstalled }
        if ours != [Self.loadPath] { return .updateAvailable }
        guard let installed = FileManager.default.contents(atPath: installedDylib) else { return .updateAvailable }
        if let bundled = bundledDylib, let data = try? Data(contentsOf: bundled), data != installed { return .updateAvailable }
        return .installed
    }

    /// Installs or updates. Returns what was done, for the log.
    func install() throws -> String {
        guard FileManager.default.fileExists(atPath: executable) else { throw Failure.gameNotFound(gameDir) }
        guard !gameRunning else { throw Failure.gameRunning }
        guard let bundled = bundledDylib, FileManager.default.fileExists(atPath: bundled.path) else {
            throw Failure.noBundledLibrary
        }
        var done: [String] = []
        let original = try Data(contentsOf: URL(fileURLWithPath: executable))
        var patcher = try MachOPatcher(original)
        // Keep a copy of the executable as it was without the companion (only then: an existing
        // backup is not overwritten with a patched file).
        if !patcher.dylibs.contains(where: Self.isOurs) {
            try replace(backup, with: original, mode: 0o755)
            done.append("backed up the executable to \((backup as NSString).lastPathComponent)")
        }
        // The library first: the patched executable must never point at a missing file.
        try replace(installedDylib, with: Data(contentsOf: bundled), mode: 0o755)
        removexattr(installedDylib, "com.apple.quarantine", 0)  // a downloaded app's copy would not load
        done.append("copied \(Self.dylibName)")
        let old = patcher.removeDylibs { Self.isOurs($0) && $0 != Self.loadPath }
        if old > 0 { done.append("removed \(old) older load command(s)") }
        if !patcher.dylibs.contains(Self.loadPath) {
            try patcher.addDylib(Self.loadPath)
            done.append("added the load command")
        }
        if patcher.data != original {
            try replace(executable, with: patcher.data, mode: 0o755)
        }
        for name in Self.oldNames {
            let path = macOSDir + "/" + name
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                done.append("deleted \(name)")
            }
        }
        return done.joined(separator: "; ")
    }

    /// Removes the companion: its load command(s) (the rest of the executable stays as it is,
    /// custom-song patch included) and the library. The backup is kept.
    func uninstall() throws -> String {
        guard FileManager.default.fileExists(atPath: executable) else { throw Failure.gameNotFound(gameDir) }
        guard !gameRunning else { throw Failure.gameRunning }
        var done: [String] = []
        let original = try Data(contentsOf: URL(fileURLWithPath: executable))
        var patcher = try MachOPatcher(original)
        let removed = patcher.removeDylibs(where: Self.isOurs)
        if removed > 0 {
            try replace(executable, with: patcher.data, mode: 0o755)
            done.append("removed \(removed) load command(s)")
        }
        for name in [Self.dylibName] + Self.oldNames {
            let path = macOSDir + "/" + name
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
                done.append("deleted \(name)")
            }
        }
        return done.isEmpty ? "nothing to remove" : done.joined(separator: "; ")
    }

    /// Writes a file next to its destination and renames it into place, so a reader (or a game
    /// starting) never sees a half-written file.
    private func replace(_ path: String, with data: Data, mode: Int) throws {
        let temp = path + ".rscompanion-tmp"
        do {
            try data.write(to: URL(fileURLWithPath: temp))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp)
            if rename(temp, path) != 0 { throw Failure.failed("cannot replace \(path): \(String(cString: strerror(errno)))") }
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw error
        }
    }
}
