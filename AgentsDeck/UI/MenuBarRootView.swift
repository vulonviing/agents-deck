import AppKit
import SwiftUI

struct MenuBarRootView: View {
    let sessionID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @State private var refreshTurns = 0.0
    @State private var detailProvider: ProviderID?

    var body: some View {
        Group {
            if onboardingCompleted { dashboard }
            else { OnboardingView(onboardingCompleted: $onboardingCompleted) }
        }
        .id(sessionID)
        .frame(
            minWidth: DeckDesign.popoverMinimumWidth,
            idealWidth: DeckDesign.popoverIdealWidth,
            maxWidth: DeckDesign.popoverMaximumWidth,
            minHeight: DeckDesign.popoverMinimumHeight,
            idealHeight: DeckDesign.popoverIdealHeight,
            maxHeight: DeckDesign.popoverMaximumHeight
        )
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Color.primary.opacity(0.025) }
        }
        .glassEffect(
            reduceTransparency ? .identity : .regular,
            in: .rect(cornerRadius: 24)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .alert("Agents Deck", isPresented: errorBinding) {
            Button("OK") { model.presentedError = nil }
                .help("Dismiss this error")
        } message: {
            Text(model.presentedError ?? "")
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents Deck")
                        .font(DeckDesign.font(18, weight: .medium))
                    Text("Local usage, quietly monitored.")
                        .font(DeckDesign.font(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Menu {
                        ForEach(RefreshCadence.allCases, id: \.self) { cadence in
                            Button {
                                model.setRefreshCadence(cadence)
                            } label: {
                                Label(
                                    cadence.displayName,
                                    systemImage: model.refreshCadence == cadence ? "checkmark" : "clock"
                                )
                            }
                            .help("Refresh providers every \(cadence.displayName.lowercased())")
                        }
                    } label: {
                        Image(systemName: "timer")
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .deckInteractive(
                        help: "Choose the automatic refresh interval. Current: \(model.refreshCadence.displayName)"
                    )

                    Menu {
                        ForEach(ProviderID.allCases) { provider in
                            Button {
                                model.toggleMenuBarProvider(provider)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: model.menuBarProviders.contains(provider) ? "checkmark.square.fill" : "square")
                                    ProviderSelectionMark(providers: [provider])
                                    Text(provider.displayName)
                                }
                            }
                            .disabled(model.menuBarProviders == [provider])
                        }
                    } label: {
                        ProviderSelectionMark(providers: model.menuBarProviders)
                            .frame(minWidth: 30, minHeight: 30)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .deckInteractive(
                        help: "Choose providers shown in the menu bar"
                    )
                    .accessibilityLabel("Choose providers shown in the menu bar")

                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(reduceMotion ? 0 : refreshTurns * 360))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .deckInteractive(help: "Refresh all providers now")
                    .accessibilityLabel("Refresh usage")
                }
            }
            .padding(.horizontal, DeckDesign.pagePadding)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let detailProvider {
                ProviderDetailView(provider: detailProvider) { self.detailProvider = nil }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(ProviderID.allCases) { provider in
                            ProviderCardView(
                                state: model.state.providers[provider] ?? .empty(provider),
                                preferredKind: model.selectedUsageWindow(for: provider),
                                selectedAntigravityMetric: model.selectedAntigravityMetric(),
                                antigravityGroupOrder: model.antigravityGroupOrder,
                                onShowDetails: {
                                    detailProvider = provider
                                },
                                onSelectWindow: { model.selectUsageWindow($0, for: provider) },
                                onSelectAntigravityMetric: { model.selectAntigravityMetric($0) },
                                onMoveAntigravityGroup: { model.moveAntigravityGroup($0, to: $1) }
                            )
                        }
                    }
                    .padding(.horizontal, DeckDesign.pagePadding)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func refresh() {
        if reduceMotion {
            model.refreshNow()
        } else {
            withAnimation(.easeInOut(duration: 0.5)) { refreshTurns += 1 }
            model.refreshNow()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )
    }
}

private struct ProviderSelectionMark: View {
    let providers: [ProviderID]

    var body: some View {
        Image(nsImage: markImage)
            .renderingMode(.template)
            .foregroundStyle(.primary)
            .frame(width: markWidth, height: 18)
            .clipped()
        .accessibilityHidden(true)
    }

    private var markWidth: CGFloat {
        CGFloat(providers.count * 15 + max(0, providers.count - 1) * 2)
    }

    private var markImage: NSImage {
        let size = NSSize(width: markWidth, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, provider) in providers.enumerated() {
                guard let mark = NSImage(named: NSImage.Name(markName(for: provider))) else { continue }
                mark.draw(
                    in: NSRect(x: CGFloat(index * 17), y: 1.5, width: 15, height: 15),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func markName(for provider: ProviderID) -> String {
        switch provider {
        case .claude: "ClaudeProviderMark"
        case .codex: "CodexProviderMark"
        case .antigravity: "AntigravityProviderMark"
        }
    }
}
