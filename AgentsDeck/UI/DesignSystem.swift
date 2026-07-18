import SwiftUI

enum DeckDesign {
    static let popoverMinimumWidth: CGFloat = 430
    static let popoverIdealWidth: CGFloat = 430
    static let popoverMaximumWidth: CGFloat = 600
    static let popoverMinimumHeight: CGFloat = 440
    static let popoverIdealHeight: CGFloat = 520
    static let popoverMaximumHeight: CGFloat = 680
    static let cornerRadius: CGFloat = 18
    static let pagePadding: CGFloat = 16
    static let windowCoral = Color(red: 0.941, green: 0.600, blue: 0.482)
    static let connected = Color(red: 0.65, green: 0.79, blue: 0.48)
    static let stale = Color(red: 1.0, green: 0.78, blue: 0.38)
    static let ringTrack = Color.primary.opacity(0.12)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

enum DeckInteractiveStyle {
    case compact
    case row
}

private struct DeckInteractiveHoverModifier: ViewModifier {
    let helpText: String
    let style: DeckInteractiveStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let active = isHovering && isEnabled && !reduceMotion
        content
            .scaleEffect(active ? hoverScale : 1)
            .offset(y: active ? -1 : 0)
            .animation(.easeOut(duration: 0.14), value: active)
            .onHover { isHovering = $0 }
            .help(helpText)
    }

    private var hoverScale: CGFloat {
        switch style {
        case .compact: 1.04
        case .row: 1.012
        }
    }
}

struct DeckCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DeckDesign.cornerRadius, style: .continuous)
        content
            .padding(14)
            .background {
                shape.fill(
                    reduceTransparency
                        ? Color(nsColor: .windowBackgroundColor)
                        : Color.primary.opacity(0.045)
                )
            }
            .glassEffect(
                reduceTransparency ? .identity : .regular,
                in: .rect(cornerRadius: DeckDesign.cornerRadius)
            )
            .overlay {
                shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

extension View {
    func deckCard() -> some View { modifier(DeckCardModifier()) }

    func deckInteractive(
        help helpText: String,
        style: DeckInteractiveStyle = .compact
    ) -> some View {
        modifier(DeckInteractiveHoverModifier(helpText: helpText, style: style))
    }
}
