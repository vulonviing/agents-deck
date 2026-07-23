import SwiftUI

struct ProviderDetailView: View {
    let provider: ProviderID
    let onBack: () -> Void
    @Environment(AppModel.self) private var model

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
                    detailCard {
                        detailRow("CLI", state.executableVersion ?? "Not provided")
                        detailRow("Source", sourceLabel)
                        detailRow("Status", state.connection.label)
                        detailRow("Restarts", "\(state.restartCount)")
                        if let capturedAt = state.snapshot?.capturedAt {
                            detailRow("Last verified", capturedAt.formatted(date: .abbreviated, time: .standard))
                        }
                    }

                    if provider == .codex {
                        CodexAccountActivityView(state: state)
                    }
                }
                .padding(.horizontal, DeckDesign.pagePadding)
                .padding(.bottom, 12)
            }
        }
        .task { model.providerDetailOpened(provider) }
    }

    private var sourceLabel: String {
        provider == .claude ? "Claude status-line bridge" : "Codex app-server"
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
