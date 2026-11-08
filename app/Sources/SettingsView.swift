import ServiceManagement
import SwiftUI

/// Device profile, lead time and launch at login. Changes apply at once.
struct SettingsView: View {
    @ObservedObject var companion: Companion
    let done: () -> Void
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?
    @State private var keyText = ""
    @State private var hasKey = APIKey.get() != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: done) { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text("Settings").font(.headline)
            }

            section("MIDI output") {
                Picker("Device profile", selection: Binding(get: { companion.settings.profile ?? Profile.defaultID },
                                                            set: { companion.chooseProfile($0) })) {
                    ForEach(companion.profiles) { Text($0.name).tag($0.id) }
                }
                Text(companion.profile.summary).font(.caption).foregroundStyle(.secondary)
                if let problem = companion.profileError ?? companion.outputProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("A profile says what's sent for each song and tone. Add or edit one as a JSON file.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Profiles") { open(companion.profilesFolder) }
                }
                if let made = companion.madeTones {
                    Text(made.summary).font(.caption).lineLimit(3)
                }
            }

            section("AI (experimental)") {
                Toggle("Ask an AI model about new songs", isOn: binding(\.aiClassify))
                Text("The first time a song loads, its artist, title and what the rules measured go to OpenAI, which "
                     + "says the song's style and whether its distortion should be Crunch or Heavy. The window shows "
                     + "the answer, to accept or reject. Your own overrides always win.")
                    .font(.caption).foregroundStyle(.secondary)
                if hasKey {
                    HStack {
                        Text("OpenAI API key saved in the keychain").font(.caption)
                        Spacer()
                        Button("Remove") {
                            APIKey.set(nil)
                            hasKey = false
                        }
                    }
                } else {
                    HStack {
                        SecureField("OpenAI API key", text: $keyText)
                        Button("Save") {
                            APIKey.set(keyText)
                            keyText = ""
                            hasKey = APIKey.get() != nil
                            companion.apiKeyChanged()
                        }
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                TextField("Model", text: binding(\.aiModel))
                    .font(.caption)
                    .help("The OpenAI model to ask (\(AIClassifier.defaultModel) by default)")
            }

            section("Timing") {
                Stepper(value: binding(\.leadMs), in: 0...1000, step: 25) {
                    Text("Switch \(companion.settings.leadMs) ms early")
                }
                Text("Sends each change this much before the song's change time, to cover the time your gear needs "
                     + "to switch. The game picks it up within a second.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            section("Rocksmith") {
                Text(companion.installer.gameDir).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                HStack {
                    Button("Change Folder…", action: chooseGameDir)
                    if companion.settings.gameDir != nil {
                        Button("Use Steam's") { companion.setGameDir(nil) }
                    }
                }
                Text(companion.installStatus.summary).font(.callout)
                HStack {
                    switch companion.installStatus {
                    case .notInstalled: Button("Install") { companion.installInGame() }
                    case .updateAvailable: Button("Update") { companion.installInGame() }
                    case .installed: Button("Reinstall") { companion.installInGame() }
                    default: EmptyView()
                    }
                    if companion.installStatus == .installed || companion.installStatus == .updateAvailable {
                        Button("Uninstall") { companion.uninstallFromGame() }
                    }
                }
                if let message = companion.installMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text(companion.installer.usesModsFolder
                     ? "Installing puts one library in RS Re-ARMed's mods folder (Rocksmith must not be running); "
                       + "the game itself isn't changed, and a reinstall of RS Re-ARMed keeps it. Uninstalling removes it."
                     : "Installing adds one library to the game (Rocksmith must not be running); a backup of the "
                       + "game is kept. Uninstalling removes only the companion. After a Steam update, install again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            section("RockNRoller") {
                Text(RockNRoller.appURL?.path ?? "Not found (install it in Applications)").font(.caption)
                    .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if RockNRoller.appURL != nil {
                    Button(companion.rnrRunning ? "Restart RockNRoller" : "Open RockNRoller") { companion.openRockNRoller() }
                }
                if let message = companion.rnrMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text("Nothing is installed into RockNRoller: opened from here, it loads the companion library. "
                     + "Opened another way (Dock, Finder), it runs without it; restart it from here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            section("Stream overlays (RockSniffer compatible)") {
                Toggle("Serve overlays", isOn: binding(\.overlayEnabled))
                if companion.settings.overlayEnabled {
                    Stepper(value: binding(\.overlayPort), in: 1024...65535) {
                        Text(verbatim: "Port \(companion.settings.overlayPort)")
                    }
                    if let problem = companion.overlay.problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    DisclosureGroup("Overlay pages for OBS") {
                        ForEach(overlayPages, id: \.self) { page in
                            HStack {
                                Text(page.components(separatedBy: "/").first ?? page).font(.callout)
                                Spacer()
                                Button("Copy URL") { copy(overlayURL(page)) }.controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        Button("Open Addons") { open(URL(string: overlayURL(""))) }
                        Button("Show Text Files") { open(URL(fileURLWithPath: companion.overlay.outputDir)) }
                    }
                }
                Text("RockSniffer's overlay pages and API on 127.0.0.1 for OBS browser sources, plus its text files "
                     + "and album_cover.jpeg for text and image sources. Turn it off when you don't stream: the game "
                     + "then doesn't look for the note statistics. Overlay pages and API by RockSniffer "
                     + "(kokolihapihvi and contributors, MIT).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            section("General") {
                Toggle("Open at login", isOn: Binding(get: { loginItem }, set: setLoginItem))
                if let loginProblem {
                    Text(loginProblem).font(.caption).foregroundStyle(.red)
                }
                Text("RS Companion \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    /// A binding that saves the whole settings on every change.
    private func binding<Value>(_ key: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(get: { companion.settings[keyPath: key] }, set: { value in
            var s = companion.settings
            s[keyPath: key] = value
            companion.update(s)
        })
    }

    /// The bundled addons' pages, as "<addon>/<page>.html".
    private var overlayPages: [String] {
        guard let root = companion.overlay.addonsDir else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
            .filter { $0 != "_deps" && !$0.hasPrefix(".") && !$0.contains(".") }
            .map { "\($0)/\(OverlayServer.entry(root, $0))" }
    }

    private func overlayURL(_ page: String) -> String {
        "http://127.0.0.1:\(companion.settings.overlayPort)/addons/\(page)"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }

    private func chooseGameDir() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Rocksmith2014 folder or Rocksmith2014.app."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true  // so Rocksmith2014.app can be picked
        panel.directoryURL = URL(fileURLWithPath: companion.installer.gameDir)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let dir = GameInstaller.gameDir(for: url.path) else {
            companion.notGame(url.lastPathComponent)
            return
        }
        companion.setGameDir(dir == GameInstaller.steamGameDir() ? nil : dir)
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = SMAppService.mainApp.status == .requiresApproval
                ? "Allow RS Companion in System Settings › General › Login Items." : nil
        } catch {
            loginProblem = error.localizedDescription
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}
