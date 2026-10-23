import AppKit
import Foundation

/// RockNRoller (a Rocksmith chart player for macOS): finds it, tells whether it runs, and opens it
/// with the companion library (librnrcompanion.dylib, bundled in this app) loaded. Unlike
/// Rocksmith, nothing is installed into it: the library is loaded at launch through
/// DYLD_INSERT_LIBRARIES, so RockNRoller has to be opened from here (or restarted from here).
@MainActor
enum RockNRoller {
    static let bundleID = "com.mintricksai.rocknroller"
    static let name = "RockNRoller"
    /// The "game" of the library's heartbeats.
    static let game = "rocknroller"

    enum Failure: Error, CustomStringConvertible {
        case notFound, noBundledLibrary, stillRunning, failed(String)
        var description: String {
            switch self {
            case .notFound: "RockNRoller not found. Install it in Applications."
            case .noBundledLibrary: "This app does not contain the RockNRoller library (build it with app/build.sh)."
            case .stillRunning: "RockNRoller did not quit; quit it and try again."
            case let .failed(text): text
            }
        }
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var bundledLibrary: URL? { Bundle.main.url(forResource: "librnrcompanion", withExtension: "dylib") }

    static var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    /// Opens RockNRoller with the library, quitting it first if it runs (it then starts over in
    /// its catalog). The library writes to dataDir, like this app.
    static func open(dataDir: String) async throws {
        guard let app = appURL else { throw Failure.notFound }
        guard let library = bundledLibrary else { throw Failure.noBundledLibrary }
        for old in running { old.terminate() }
        for _ in 0..<50 where !running.isEmpty { try await Task.sleep(nanoseconds: 200_000_000) }
        if !running.isEmpty { throw Failure.stillRunning }
        let config = NSWorkspace.OpenConfiguration()
        config.environment = ["DYLD_INSERT_LIBRARIES": library.path, "RS_COMPANION_DATA": dataDir]
        config.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
        } catch {
            throw Failure.failed("Could not open RockNRoller: \(error.localizedDescription)")
        }
    }
}
