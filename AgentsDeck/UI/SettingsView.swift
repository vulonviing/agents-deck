import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClearLogs = false
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            aboutHeader
            Divider().opacity(0.5)

            Form {
                Section("Menu Bar") {
                    Toggle("Show Agents Deck in the menu bar", isOn: menuBarVisibilityBinding)
                        .toggleStyle(.switch)
                        .help(
                            model.isMenuBarItemVisible
                                ? "Remove Agents Deck from the menu bar; reopen the app to restore it"
                                : "Restore Agents Deck to the menu bar"
                        )
                    Text("If you hide the item, reopen Agents Deck from Applications to return here and restore it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Providers") {
                    ForEach(ProviderID.allCases) { provider in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(providerSummary(provider))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose Executable…") { model.chooseExecutable(for: provider) }
                                .deckInteractive(help: "Choose the \(provider.displayName) CLI executable")
                            if provider == .codex {
                                Button("Connect") { model.connect(.codex) }
                                    .deckInteractive(help: "Connect Codex through its official login flow")
                            } else if provider == .antigravity {
                                Button("Open CLI") { model.openAntigravityCLI() }
                                    .deckInteractive(help: "Sign in through the Antigravity CLI in Terminal")
                            }
                        }
                    }
                    if model.state.providers[.claude]?.bridgeInstalled == true {
                        Button("Remove Claude Bridge", role: .destructive) { model.uninstallClaudeBridge() }
                            .deckInteractive(help: "Remove the Claude bridge and restore its previous status-line setting")
                    } else {
                        Button("Install Claude Bridge") { model.installClaudeBridge() }
                            .deckInteractive(help: "Install the reversible Claude live-update bridge")
                    }
                }

                Section("General") {
                    LabeledContent("Launch at Login") {
                        Button(model.launchAtLoginEnabled ? "Enabled" : "Disabled") {
                            model.setLaunchAtLogin(!model.launchAtLoginEnabled)
                        }
                        .deckInteractive(
                            help: model.launchAtLoginEnabled
                                ? "Disable launching Agents Deck when you log in"
                                : "Launch Agents Deck when you log in"
                        )
                    }
                    Button("Request Notification Permission") { model.requestNotifications() }
                        .deckInteractive(help: "Request macOS permission for usage limit notifications")
                }

                Section("Diagnostics") {
                    if !model.state.historyPersistenceAvailable {
                        Label("Usage history is unavailable for this run.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    Button("Reveal Logs") { model.revealLogs() }
                        .deckInteractive(help: "Open the local diagnostic logs folder in Finder")
                    Button("Clear Logs…", role: .destructive) { confirmClearLogs = true }
                        .deckInteractive(help: "Permanently remove local diagnostic logs")
                    Button("Clear Usage History…", role: .destructive) { confirmClearHistory = true }
                        .deckInteractive(help: "Permanently remove stored usage snapshots and alert receipts")
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .font(DeckDesign.font(13))
        .confirmationDialog("Clear diagnostic logs?", isPresented: $confirmClearLogs) {
            Button("Clear Logs", role: .destructive) { model.clearLogs() }
                .help("Confirm permanent deletion of diagnostic logs")
        } message: {
            Text("This permanently removes Agents Deck JSONL log files from this Mac.")
        }
        .confirmationDialog("Clear usage history?", isPresented: $confirmClearHistory) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
                .help("Confirm permanent deletion of usage history")
        } message: {
            Text("This permanently removes stored usage snapshots and notification receipts.")
        }
    }

    private var aboutHeader: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Agents Deck")
                    .font(DeckDesign.font(22, weight: .medium))
                Text("Local usage, quietly monitored.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    Text("Version \(versionText)")
                    Text("·").foregroundStyle(.tertiary)
                    Text("Released \(releaseDateText)")
                }
                .font(DeckDesign.font(11).monospacedDigit())
                .foregroundStyle(.secondary)

                if let repositoryURL = URL(string: "https://github.com/vulonviing/agents-deck") {
                    Link("github.com/vulonviing/agents-deck", destination: repositoryURL)
                        .font(DeckDesign.font(11, weight: .medium))
                        .help("Open the Agents Deck source repository")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var releaseDateText: String {
        guard let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 7, day: 19)
        ) else { return "July 19, 2026" }
        return date.formatted(date: .long, time: .omitted)
    }

    private var menuBarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { model.isMenuBarItemVisible },
            set: { model.setMenuBarItemVisible($0) }
        )
    }

    private func providerSummary(_ provider: ProviderID) -> String {
        let state = model.state.providers[provider] ?? .empty(provider)
        var parts = [state.connection.label]
        if let version = state.executableVersion { parts.append(version) }
        if provider == .codex, state.restartCount > 0 { parts.append("\(state.restartCount) restarts") }
        return parts.joined(separator: " · ")
    }
}
