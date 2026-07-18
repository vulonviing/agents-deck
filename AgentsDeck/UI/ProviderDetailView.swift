import SwiftUI

struct ProviderDetailView: View {
    let provider: ProviderID
    let onBack: () -> Void
    @Environment(AppModel.self) private var model
    @State private var confirmEnable = false
    @State private var confirmDisable = false

    private var state: ProviderViewState {
        model.state.providers[provider] ?? .empty(provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .deckInteractive(help: "Return to the usage deck")
                Spacer()
                ProviderLogo(provider: provider)
                Text("\(provider.displayName) details")
                    .font(DeckDesign.font(15, weight: .medium))
            }
            .padding(.horizontal, DeckDesign.pagePadding)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if provider == .claude { claudeDetails }
                    else { codexDetails }
                }
                .padding(.horizontal, DeckDesign.pagePadding)
                .padding(.bottom, 12)
            }
        }
        .task(id: model.sessionHistoryRange) {
            await model.loadSessionConfigurations(for: provider)
        }
        .onChange(of: state.latestSessionConfiguration?.capturedAt) {
            Task { await model.loadSessionConfigurations(for: provider) }
        }
        .confirmationDialog("Enable Claude session details?", isPresented: $confirmEnable) {
            Button("Enable Session Details") { model.enableClaudeSessionDetails() }
        } message: {
            Text("Agents Deck will store only Claude's documented model, effort, thinking and agent labels on this Mac for up to 365 days. It never stores prompts, responses, paths or session identifiers.")
        }
        .confirmationDialog("Disable and clear Claude session details?", isPresented: $confirmDisable) {
            Button("Disable and Clear", role: .destructive) { model.disableClaudeSessionDetails() }
        } message: {
            Text("Usage monitoring stays enabled. Stored session configuration history will be permanently removed.")
        }
    }

    @ViewBuilder
    private var claudeDetails: some View {
        if state.sessionDetailsEnabled {
            HStack {
                Text("Configuration history")
                    .font(DeckDesign.font(13, weight: .medium))
                Spacer()
                Picker("History range", selection: Binding(
                    get: { model.sessionHistoryRange },
                    set: { model.setSessionHistoryRange($0) }
                )) {
                    ForEach(SessionHistoryRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .deckInteractive(help: "Choose how much local Claude configuration history to show")
            }

            if model.sessionHistoryLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if model.sessionConfigurations.isEmpty {
                detailCard {
                    Text("Waiting for Claude Code to emit its next documented status-line payload.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.sessionConfigurations) { period in
                    detailCard { configurationPeriod(period) }
                }
            }

            Button("Disable Session Details…", role: .destructive) { confirmDisable = true }
                .deckInteractive(help: "Stop collecting and remove Claude session configuration history")
        } else {
            detailCard {
                Text("Session details are off")
                    .font(DeckDesign.font(13, weight: .medium))
                Text("Enable them to record Claude's documented model, effort, thinking and agent labels. Usage monitoring is separate.")
                    .foregroundStyle(.secondary)
                Button("Enable Session Details…") { confirmEnable = true }
                    .deckInteractive(help: "Review consent and enable sanitized Claude session details")
            }
        }
    }

    private var codexDetails: some View {
        VStack(spacing: 10) {
            detailCard {
                Text("Session configuration")
                    .font(DeckDesign.font(13, weight: .medium))
                detailRow("Model", "Not provided")
                detailRow("Effort", "Not provided")
                Text("Codex rate-limit data does not identify the model or reasoning effort. Agents Deck does not inspect threads or conversation history to infer it.")
                    .font(DeckDesign.font(10))
                    .foregroundStyle(.secondary)
            }
            detailCard {
                detailRow("CLI", state.executableVersion ?? "Not provided")
                detailRow("Source", "Codex app-server")
                detailRow("Status", state.connection.label)
                detailRow("Restarts", "\(state.restartCount)")
                if let capturedAt = state.snapshot?.capturedAt {
                    detailRow("Last verified", capturedAt.formatted(date: .abbreviated, time: .standard))
                }
            }
        }
    }

    private func configurationPeriod(_ period: SessionConfigurationPeriod) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(period.modelDisplayName ?? period.modelID)
                .font(DeckDesign.font(13, weight: .medium))
            if period.modelDisplayName != nil { detailRow("Model ID", period.modelID) }
            detailRow("Effort", period.effort ?? "Not provided")
            detailRow("Thinking", period.thinkingEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Not provided")
            detailRow("Agent", period.agentName ?? "Not provided")
            detailRow("Seen", seenRange(period))
        }
    }

    private func seenRange(_ period: SessionConfigurationPeriod) -> String {
        if period.firstSeenAt == period.lastSeenAt {
            return period.lastSeenAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "\(period.firstSeenAt.formatted(date: .abbreviated, time: .shortened)) – \(period.lastSeenAt.formatted(date: .omitted, time: .shortened))"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(DeckDesign.font(10))
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckCard()
    }
}
