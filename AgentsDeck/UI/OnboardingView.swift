import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Binding var onboardingCompleted: Bool
    @State private var step = 0
    @State private var bridgeConsent = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .symbolRenderingMode(.monochrome)
                Text(title)
                    .font(DeckDesign.font(22, weight: .medium))
                content
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
            .padding(DeckDesign.pagePadding)

            Divider().opacity(0.5)
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .deckInteractive(help: "Return to the previous setup step")
                }
                Spacer()
                Button(step == 5 ? "Finish" : "Continue") {
                    if step == 5 { onboardingCompleted = true }
                    else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .deckInteractive(
                    help: step == 5 ? "Finish setup and open Agents Deck" : "Continue to the next setup step"
                )
            }
            .padding(DeckDesign.pagePadding)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            Text("Agents Deck reads verified usage from the Claude, Codex, and Antigravity tools already installed on this Mac. There is no Agents Deck account, server, telemetry, or cloud sync.")
                .foregroundStyle(.secondary)
        case 1:
            providerStatus
            Text("Missing a CLI? Choose its executable now or continue and configure it later in Settings.")
                .font(DeckDesign.font(11))
                .foregroundStyle(.secondary)
        case 2:
            setupRow(.codex, actionTitle: "Connect Codex") { model.connect(.codex) }
            setupRow(.claude, actionTitle: "Copy login command") { model.openClaudeLogin() }
            setupRow(.antigravity, actionTitle: "Open CLI") { model.openAntigravityCLI() }
            Text("Claude and Antigravity authentication stay in Terminal. Codex opens the official app-server login page in your browser.")
                .font(DeckDesign.font(11))
                .foregroundStyle(.secondary)
        case 3:
            Text("Agents Deck can refresh limits through Claude's local /usage command. The optional status-line bridge adds instant updates after responses and verified session cost. It backs up and merges your settings and stores only rate limits and cost.")
                .foregroundStyle(.secondary)
            Toggle("I allow Agents Deck to update ~/.claude/settings.json", isOn: $bridgeConsent)
                .deckInteractive(help: "Allow the reversible Claude status-line bridge installation", style: .row)
            Button("Install Claude Bridge") { model.installClaudeBridge() }
                .disabled(!bridgeConsent)
                .deckInteractive(help: "Install the reversible Claude live-update bridge")
        case 4:
            Text("Optional Claude and Codex alerts appear once at 80% and once at 95% for each usage window. Antigravity does not send alerts.")
                .foregroundStyle(.secondary)
            Button(model.notificationsGranted ? "Notifications enabled" : "Enable Notifications") {
                model.requestNotifications()
            }
            .disabled(model.notificationsGranted)
            .deckInteractive(help: "Request macOS permission for usage limit notifications")
        default:
            Text("Setup is complete. Providers can be connected independently, and every integration can be reviewed or removed from Settings.")
                .foregroundStyle(.secondary)
            Label("Local-only storage", systemImage: "internaldrive")
            Label("No prompts or responses", systemImage: "text.badge.xmark")
            Label("One lightweight refresh loop", systemImage: "clock.arrow.circlepath")
        }
    }

    private var providerStatus: some View {
        VStack(spacing: 10) {
            ForEach(ProviderID.allCases) { provider in
                HStack {
                    Text(provider.displayName)
                    Spacer()
                    Text(model.state.providers[provider]?.connection.label ?? "Checking")
                        .foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseExecutable(for: provider) }
                        .deckInteractive(help: "Choose the \(provider.displayName) CLI executable")
                }
            }
        }
        .deckCard()
    }

    private func setupRow(_ provider: ProviderID, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(provider.displayName).fontWeight(.medium)
                Text(model.state.providers[provider]?.connection.label ?? "Checking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
                .deckInteractive(help: "\(actionTitle) for \(provider.displayName)")
        }
        .deckCard()
    }

    private var title: String {
        ["Welcome", "Find your tools", "Connect providers", "Claude live updates", "Usage alerts", "Ready"][step]
    }

    private var symbol: String {
        ["rectangle.stack", "terminal", "link", "lock.shield", "bell", "checkmark.circle"][step]
    }
}
