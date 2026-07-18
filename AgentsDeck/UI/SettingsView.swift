import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClearLogs = false
    @State private var confirmClearHistory = false
    @State private var confirmEnableSessionDetails = false
    @State private var confirmDisableSessionDetails = false
    @State private var confirmClearSessionDetails = false

    var body: some View {
        Form {
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

            Section("Claude Session Details") {
                Text("Optional local history of documented model, effort, thinking and agent labels. Prompts, responses, paths and session identifiers are never stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.state.providers[.claude]?.sessionDetailsEnabled == true {
                    Button("Disable and Clear…", role: .destructive) { confirmDisableSessionDetails = true }
                        .deckInteractive(help: "Stop collecting and clear Claude session configuration history")
                    Button("Clear Session Details History…", role: .destructive) { confirmClearSessionDetails = true }
                        .deckInteractive(help: "Clear stored session details while keeping collection enabled")
                } else {
                    Button("Enable Session Details…") { confirmEnableSessionDetails = true }
                        .deckInteractive(help: "Review consent and enable sanitized Claude session details")
                }
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
        .padding()
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
        .confirmationDialog("Enable Claude session details?", isPresented: $confirmEnableSessionDetails) {
            Button("Enable Session Details") { model.enableClaudeSessionDetails() }
        } message: {
            Text("Only Claude's documented model, effort, thinking and agent labels are stored locally for up to 365 days. Prompts, responses, paths and session identifiers are excluded.")
        }
        .confirmationDialog("Disable and clear session details?", isPresented: $confirmDisableSessionDetails) {
            Button("Disable and Clear", role: .destructive) { model.disableClaudeSessionDetails() }
        } message: {
            Text("Usage monitoring stays enabled. Stored Claude session configuration history is permanently removed.")
        }
        .confirmationDialog("Clear session details history?", isPresented: $confirmClearSessionDetails) {
            Button("Clear History", role: .destructive) { model.clearSessionDetails() }
        } message: {
            Text("Collection remains enabled, but existing session configuration history is permanently removed.")
        }
    }

    private func providerSummary(_ provider: ProviderID) -> String {
        let state = model.state.providers[provider] ?? .empty(provider)
        var parts = [state.connection.label]
        if let version = state.executableVersion { parts.append(version) }
        if provider == .codex, state.restartCount > 0 { parts.append("\(state.restartCount) restarts") }
        return parts.joined(separator: " · ")
    }
}
