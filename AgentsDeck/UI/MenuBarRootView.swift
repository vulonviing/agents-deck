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
                            .help("Refresh both providers every \(cadence.displayName.lowercased())")
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
                        ForEach(MenuBarProviderSelection.allCases, id: \.self) { selection in
                            Button {
                                model.setMenuBarProviderSelection(selection)
                            } label: {
                                HStack(spacing: 7) {
                                    ProviderSelectionMark(selection: selection)
                                        .frame(width: 18, height: 18)
                                    Text(selection.displayName)
                                    if model.menuBarProviderSelection == selection {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        ProviderSelectionMark(selection: model.menuBarProviderSelection)
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .deckInteractive(
                        help: "Choose providers shown in the menu bar. Current: \(model.menuBarProviderSelection.displayName)"
                    )
                    .accessibilityLabel("Choose providers shown in the menu bar")

                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(reduceMotion ? 0 : refreshTurns * 360))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .deckInteractive(help: "Refresh Claude and Codex now")
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
                                onShowDetails: { detailProvider = provider },
                                onSelectWindow: { model.selectUsageWindow($0, for: provider) }
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
    let selection: MenuBarProviderSelection

    var body: some View {
        Image(nsImage: selection.compactMenuImage)
            .renderingMode(.template)
            .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}

private extension MenuBarProviderSelection {
    @MainActor
    var compactMenuImage: NSImage {
        ProviderSelectionImageCache.images[self] ?? NSImage(size: NSSize(width: 18, height: 18))
    }
}

@MainActor
private enum ProviderSelectionImageCache {
    static let images: [MenuBarProviderSelection: NSImage] = Dictionary(
        uniqueKeysWithValues: MenuBarProviderSelection.allCases.map { selection in
            (selection, makeImage(for: selection))
        }
    )

    private static func makeImage(for selection: MenuBarProviderSelection) -> NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let providers = selection.providers
            let markSize: CGFloat = providers.count == 1 ? 16 : 9
            let spacing: CGFloat = providers.count == 1 ? 0 : 1
            let totalWidth = CGFloat(providers.count) * markSize + CGFloat(max(0, providers.count - 1)) * spacing
            var x = (canvas.width - totalWidth) / 2
            for provider in providers {
                let name = provider == .claude ? "ClaudeProviderMark" : "CodexProviderMark"
                guard let mark = NSImage(named: NSImage.Name(name)) else { continue }
                let rect = NSRect(x: x, y: (canvas.height - markSize) / 2, width: markSize, height: markSize)
                mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                x += markSize + spacing
            }
            return true
        }
        image.size = canvas
        image.isTemplate = true
        return image
    }
}
