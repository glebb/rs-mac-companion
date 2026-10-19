import Foundation

/// Starts the menu-bar app, or with one of these arguments does one thing and exits:
///   --game-status [game folder]      not installed / installed / update available
///   --install-game [game folder]     install or update the companion in Rocksmith
///   --uninstall-game [game folder]   remove it again
/// The game folder defaults to the settings' game_dir, else Steam's location.
@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, ["--game-status", "--install-game", "--uninstall-game"].contains(command) else {
            RSCompanionApp.main()
            return
        }
        let dataDir = ProcessInfo.processInfo.environment["RS_COMPANION_DATA"]
            ?? NSHomeDirectory() + "/Library/Application Support/rs-mac-companion"
        let gameDir = args.count > 1 ? args[1]
            : Settings.load(from: dataDir + "/rscompanion.json").gameDir ?? GameInstaller.defaultGameDir
        let installer = GameInstaller(gameDir: gameDir,
                                      bundledDylib: Bundle.main.url(forResource: "librscompanion", withExtension: "dylib"))
        do {
            switch command {
            case "--game-status": print(installer.status().summary)
            case "--install-game": print(try installer.install()); print(installer.status().summary)
            case "--uninstall-game": print(try installer.uninstall()); print(installer.status().summary)
            default: print("unknown command \(command)"); exit(2)
            }
        } catch {
            print("failed: \(error)")
            exit(1)
        }
        exit(0)
    }
}
