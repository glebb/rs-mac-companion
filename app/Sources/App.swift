import AppKit
import SwiftUI

/// Rocksmith Companion: a menu-bar app that receives tone changes from the in-game dylib (in
/// Rocksmith, or in RockNRoller) and switches presets over MIDI. Started with a command (see Main.swift) it installs instead.
struct RSCompanionApp: App {
    @ObservedObject private var companion = Companion.shared

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { Companion.shared.shutdown() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            CompanionView(companion: companion)
        } label: {
            Image(systemName: "guitars")
            if let category = companion.activeCategory, companion.connected() {
                Text(category.name)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct CompanionView: View {
    @ObservedObject var companion: Companion
    @State private var showSettings = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // The panel can't be taller than the screen: past that, scroll.
        ScrollView(.vertical) {
            Group {
                if showSettings {
                    SettingsView(companion: companion) { showSettings = false }
                } else {
                    main
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320, height: min(contentHeight, maxHeight))
    }

    /// The visible screen height less room for the menu bar gap and the panel's edges.
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 20
    }

    private var main: some View {
        // Redraw every second so the connection status follows the heartbeats.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    status(connected: companion.connected(at: context.date))
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Settings")
                }
                if let attention = companion.attention {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(attention.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let action = attention.action {
                            Button(action.label) { companion.perform(action) }
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if let message = companion.installMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let song = companion.song {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song).font(.headline)
                        Text("\(companion.artist) · \(arrangementLabel)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        ForEach(companion.tones) { row in toneRow(row) }
                    }
                    if let verdict = companion.ai { aiPanel(verdict) }
                } else {
                    Text("Pick a song in \(companion.gameLabel).").foregroundStyle(.secondary)
                    if RockNRoller.appURL != nil && !companion.rnrRunning {
                        Button("Open RockNRoller") { companion.openRockNRoller() }
                    }
                    if let message = companion.rnrMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text(companion.lastMIDI.map { "Last MIDI: \($0)" } ?? "No MIDI sent yet")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Pause MIDI", isOn: Binding(get: { companion.paused }, set: { companion.setPaused($0) }))
                HStack {
                    Button("Resend") { companion.resend() }.disabled(companion.activeCategory == nil)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                if let problem = companion.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                if let error = companion.presetsError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)
            .frame(width: 320)
        }
    }

    /// What the AI model says about this song. Its answer is in use already; while it changes
    /// something, "Keep as mine" makes the changes your own overrides and "Don't use" turns it off
    /// for the song.
    @ViewBuilder
    private func aiPanel(_ verdict: AIVerdict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch verdict.state {
            case .asking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Asking the AI about this song…")
                }
            case .answered(let a):
                HStack {
                    Text("AI: \(a.style), \(a.distortion == "none" ? "no distortion" : a.distortion)"
                         + (a.confidence == "medium" ? " (from the artist's sound)" : ""))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if !verdict.changes.isEmpty {
                        Text("In use").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    }
                }
                if !a.reason.isEmpty { Text(a.reason) }
                if verdict.changes.isEmpty {
                    Text("Nothing to change here: the rules and your overrides agree.")
                } else {
                    ForEach(verdict.changes, id: \.self) { Text("• " + $0) }
                    HStack {
                        Button("Keep as mine") { companion.acceptAI() }
                            .help("Make these changes your own overrides for this song")
                        Button("Don't use") { companion.rejectAI() }
                            .help("Go back to the rules for this song")
                    }
                }
            case .guess:
                Text("The AI doesn't know this song well enough; the rules decide.")
            case .failed(let why):
                Text("Couldn't ask the AI: \(why)").foregroundStyle(.red)
            case .rejected:
                HStack {
                    Text("AI not used for this song.")
                    Spacer()
                    Button("Use again") { companion.rejectAI(false) }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var arrangementLabel: String {
        // "skid18an_lead" -> "Lead"
        let part = companion.arrangement.split(separator: "_").last.map(String.init) ?? companion.arrangement
        return part.prefix(1).uppercased() + part.dropFirst()
    }

    private func status(connected: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            if connected {
                Text(companion.timerLocked ? "\(companion.gameLabel) connected"
                     : "\(companion.gameLabel) connected · syncing at the first tone change")
            } else {
                Text("Waiting for \(companion.gameLabel)")
            }
        }
        .font(.caption)
    }

    private func toneRow(_ row: ToneRow) -> some View {
        let active = row.slot == companion.activeSlot
        return HStack(alignment: .firstTextBaseline) {
            Text(row.slot).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.key).lineLimit(1).truncationMode(.middle)
                if !row.descriptors.isEmpty {
                    Text(row.descriptors.joined(separator: " · ").capitalized).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    if row.overridden {
                        Button { companion.override(row, to: nil) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Back to automatic (\(row.automatic.name))")
                    }
                    categoryMenu(row, active: active)
                }
                Text(reasonLabel(row)).font(.caption2).foregroundStyle(row.overridden ? Color.orange : .secondary)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(active ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    /// The category badge; picking a category changes this tone in every part of the song.
    private func categoryMenu(_ row: ToneRow, active: Bool) -> some View {
        Menu {
            Section("This tone in all parts of the song") {
                ForEach(Category.allCases, id: \.self) { c in
                    Button { companion.override(row, to: c) } label: {
                        Text(c == row.category ? "✓ \(c.name)" : c.name)
                    }
                }
            }
            Divider()
            Button("Back to automatic (\(row.automatic.name))") { companion.override(row, to: nil) }
                .disabled(!row.overridden)
        } label: {
            HStack(spacing: 3) {
                if row.overridden { Image(systemName: "pencil") }
                Text("\(row.category.name) · PC \(companion.program(for: row.category))")
            }
            .font(.caption.weight(active ? .semibold : .regular))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(row.overridden ? Color.orange.opacity(0.2)
                    : active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: Capsule())
    }

    private func reasonLabel(_ row: ToneRow) -> String {
        if row.overridden { return "changed · auto: \(row.automatic.name)" }
        if row.reason.hasSuffix(", AI") { return "AI" }
        switch row.reason {
        case "default": return "default"
        case "name": return "by name"
        default: return row.preset == row.category.name ? "by tags" : "by tags (\(row.preset))"
        }
    }
}
