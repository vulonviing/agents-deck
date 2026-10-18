import SwiftUI

struct ProviderCardView: View {
    let state: ProviderViewState
    let preferredKind: UsageWindowKind?
    let selectedAntigravityMetric: AntigravityMetricID?
    let antigravityGroupOrder: [AntigravityQuotaGroup]
    let onShowDetails: () -> Void
    let onSelectWindow: (UsageWindowKind) -> Void
    let onSelectAntigravityMetric: (AntigravityMetricID) -> Void
    let onMoveAntigravityGroup: (AntigravityQuotaGroup, AntigravityQuotaGroup) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var antigravityDropTarget: AntigravityQuotaGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: state.provider == .antigravity ? 12 : 8) {
            header
            if let snapshot = state.snapshot {
                if state.provider == .antigravity {
                    antigravityUsage(snapshot)
                    antigravityFreshness(snapshot)
                } else {
                    usage(snapshot)
                    metadata(snapshot)
                }
            } else {
                emptyState
            }
        }
        .deckCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.provider.displayName) usage")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onShowDetails) {
                headerIdentity
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .deckInteractive(
                help: "Open \(state.provider.displayName) connection details",
                style: .row
            )
            .accessibilityLabel("Open \(state.provider.displayName) connection details")
            Spacer(minLength: 8)
            statusPill
        }
    }

    private var headerIdentity: some View {
        HStack(spacing: 10) {
            ProviderLogo(provider: state.provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.provider.displayName)
                    .font(DeckDesign.font(16, weight: .medium))
                Text("CLI session")
                    .font(DeckDesign.font(10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if state.isRefreshing {
            HStack(spacing: 5) {
                if reduceMotion {
                    Image(systemName: "arrow.clockwise")
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .id(state.refreshID)
                }
                Text("Refreshing")
            }
            .font(DeckDesign.font(10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(state.provider.displayName) refreshing usage")
        } else {
            let style = statusStyle
            HStack(spacing: 5) {
                Image(systemName: style.symbol)
                Text(style.label)
                if state.connection == .stale, let capturedAt = state.snapshot?.capturedAt {
                    Text("·")
                    Text(Self.shortAge(since: capturedAt))
                        .monospacedDigit()
                }
            }
            .font(DeckDesign.font(10, weight: .medium))
            .foregroundStyle(style.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(style.color.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private func usage(_ snapshot: UsageSnapshot) -> some View {
        let descriptors = UsageRingLayout.descriptors(for: snapshot)
        let activeKind = UsageRingLayout.reconciledSelection(preferredKind, in: descriptors)
        return HStack(alignment: .center, spacing: 14) {
            ConcentricUsageGauge(
                descriptors: descriptors,
                selectedKind: activeKind,
                onSelect: select
            )
            .frame(width: 96)

            VStack(spacing: 10) {
                ForEach(descriptors) { descriptor in
                    UsageMetricRow(
                        descriptor: descriptor,
                        isSelected: descriptor.id == activeKind,
                        onSelect: { select(descriptor.id) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func select(_ kind: UsageWindowKind) {
        withAnimation(.easeInOut(duration: 0.18)) { onSelectWindow(kind) }
    }

    private func antigravityUsage(_ snapshot: UsageSnapshot) -> some View {
        let descriptors = AntigravityMetricLayout.descriptors(for: snapshot)
        let selectedMetric = selectedAntigravityMetric
            ?? AntigravityMetricID(group: .gemini4Argon, kind: .sevenDay)
        return VStack(alignment: .leading, spacing: 14) {
            Divider().opacity(0.5)
            ForEach(antigravityGroupOrder) { group in
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text(group.displayName)
                            .font(DeckDesign.font(13, weight: .medium))
                        Spacer(minLength: 8)
                        if group != .gemini4Argon {
                            Text("2 limits")
                                .font(DeckDesign.font(10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        Image(systemName: "line.3.horizontal")
                            .font(DeckDesign.font(11))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .draggable(group.rawValue)
                    .help("Drag to reorder Antigravity groups")
                    ForEach(descriptors.filter { $0.id.group == group }) { descriptor in
                        AntigravityMetricRow(
                            descriptor: descriptor,
                            isSelected: descriptor.id == selectedMetric && descriptor.window != nil,
                            onSelect: { selectAntigravityMetric(descriptor.id) }
                        )
                    }
                }
                .padding(.vertical, 2)
                .background(
                    antigravityDropTarget == group ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .dropDestination(for: String.self) { items, _ in
                    guard let value = items.first,
                          let source = AntigravityQuotaGroup(rawValue: value),
                          source != group
                    else { return false }
                    withAnimation(.easeInOut(duration: 0.18)) { onMoveAntigravityGroup(source, group) }
                    return true
                } isTargeted: { targeted in
                    antigravityDropTarget = targeted ? group : nil
                }
                .accessibilityAction(named: "Move up") {
                    guard let index = antigravityGroupOrder.firstIndex(of: group), index > 0 else { return }
                    onMoveAntigravityGroup(group, antigravityGroupOrder[index - 1])
                }
                .accessibilityAction(named: "Move down") {
                    guard let index = antigravityGroupOrder.firstIndex(of: group),
                          index < antigravityGroupOrder.count - 1 else { return }
                    onMoveAntigravityGroup(group, antigravityGroupOrder[index + 1])
                }
                if group != antigravityGroupOrder.last { Divider().opacity(0.5) }
            }
        }
    }

    private func selectAntigravityMetric(_ metric: AntigravityMetricID) {
        withAnimation(.easeInOut(duration: 0.18)) { onSelectAntigravityMetric(metric) }
    }

    private func antigravityFreshness(_ snapshot: UsageSnapshot) -> some View {
        let reachedCount = AntigravityMetricLayout.descriptors(for: snapshot)
            .filter { ($0.window?.usedPercent ?? -1) >= 100 }.count
        return VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.45)
            HStack(spacing: 8) {
                if state.connection == .connected && UsageAlgorithms.isFresh(snapshot) {
                    freshness(snapshot)
                } else {
                    Label("Last sync \(Self.shortAge(since: snapshot.capturedAt)) ago", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DeckDesign.stale)
                }
                Spacer(minLength: 4)
                if reachedCount > 0, state.connection == .connected, UsageAlgorithms.isFresh(snapshot) {
                    Label("\(reachedCount) \(reachedCount == 1 ? "limit" : "limits") reached", systemImage: "exclamationmark.circle")
                        .foregroundStyle(DeckDesign.windowCoral)
                }
            }
        }
        .font(DeckDesign.font(11, weight: .medium))
        .lineLimit(1)
    }

    private func metadata(_ snapshot: UsageSnapshot) -> some View {
        let value = state.billing ?? snapshot.billing
        return VStack(spacing: 6) {
            Divider().opacity(0.45)
            HStack(spacing: 10) {
                freshness(snapshot)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Text(value.map(billingLabel) ?? "Session cost")
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(value.map(billingText) ?? "Not provided")
                        .monospacedDigit()
                        .foregroundStyle(value == nil ? .tertiary : .primary)
                }
            }
            .font(DeckDesign.font(11, weight: .medium))
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func freshness(_ snapshot: UsageSnapshot) -> some View {
        if !UsageAlgorithms.isFresh(snapshot) {
            Label {
                Text("Last sync \(Self.shortAge(since: snapshot.capturedAt)) ago")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(DeckDesign.stale)
        } else {
            Label {
                Text("Updated \(snapshot.capturedAt, style: .relative)")
            } icon: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(state.connection.label)
                .font(DeckDesign.font(13, weight: .medium))
            Text(emptyDescription)
                .font(DeckDesign.font(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var statusStyle: (label: String, symbol: String, color: Color) {
        switch state.connection {
        case .connected: ("Connected", "checkmark", DeckDesign.connected)
        case .stale: ("Stale", "clock", DeckDesign.stale)
        case .connecting: ("Connecting", "ellipsis", .secondary)
        case .waiting: ("Waiting", "clock", .secondary)
        case .failed: ("Error", "exclamationmark.triangle", .red)
        case .needsLogin: ("Login required", "person.crop.circle.badge.exclamationmark", DeckDesign.stale)
        case .needsConsent: ("Permission required", "lock.trianglebadge.exclamationmark", DeckDesign.stale)
        case .disconnected: ("Disconnected", "minus", .secondary)
        case .unavailable: ("Unavailable", "minus", .secondary)
        }
    }

    private func billingLabel(_ billing: ProviderBillingValue) -> String {
        switch billing.kind {
        case .sessionCost: "Session cost"
        case .creditBalance, .unlimitedCredits: "Credits balance"
        case .monthlyCreditUsage: "Monthly credits"
        }
    }

    private func billingText(_ billing: ProviderBillingValue) -> String {
        switch billing.kind {
        case .sessionCost:
            guard let amount = billing.decimalValue else { return "—" }
            return amount.formatted(.currency(code: billing.currencyCode ?? "USD"))
        case .creditBalance: return billing.providerDisplayValue ?? "—"
        case .unlimitedCredits: return "Unlimited"
        case .monthlyCreditUsage:
            guard let used = billing.providerDisplayValue, let limit = billing.limitDisplayValue else { return "—" }
            return "\(used) / \(limit)"
        }
    }

    private var emptyDescription: String {
        switch state.connection {
        case .needsLogin: "Connect this provider from Settings or the setup guide."
        case .needsConsent: "Claude needs permission to install its local status-line bridge."
        case .waiting: "Waiting for verified usage from the provider CLI."
        case .unavailable: "The CLI was not found. Choose its executable in Settings."
        case .failed: "The provider returned an error. Your other provider remains available."
        default: "Verified usage is not available yet."
        }
    }

    private static func shortAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3_600 { return "\(seconds / 60) min" }
        return "\(seconds / 3_600) hr"
    }

}

struct ProviderLogo: View {
    let provider: ProviderID

    @ViewBuilder
    var body: some View {
        if provider == .claude {
            logoImage("ClaudeProviderMark", template: false)
        } else if provider == .codex {
            logoImage("CodexProviderMark", template: true)
        } else {
            logoImage("AntigravityProviderMark", template: false)
        }
    }

    private func logoImage(_ name: String, template: Bool) -> some View {
        Image(name)
            .renderingMode(template ? .template : .original)
            .resizable()
            .scaledToFit()
            .foregroundStyle(template ? Color.primary : Color.white)
            .frame(width: 20, height: 20)
            .frame(width: 36, height: 36)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

private struct ConcentricUsageGauge: View {
    let descriptors: [UsageRingDescriptor]
    let selectedKind: UsageWindowKind?
    let onSelect: (UsageWindowKind) -> Void
    @State private var isHoveringCenter = false

    var body: some View {
        ZStack {
            ForEach(descriptors.sorted(by: ringOrder)) { descriptor in
                ringButton(descriptor)
            }
            if let selected = descriptors.first(where: { $0.id == selectedKind }) {
                Text("\(Int(selected.window.usedPercent.rounded()))%")
                    .font(DeckDesign.font(16, weight: .medium).monospacedDigit())
                    .onHover { isHoveringCenter = $0 }
                    .accessibilityHidden(true)
                    .overlay(alignment: .top) {
                        if isHoveringCenter {
                            Text(selected.window.windowDisplayName)
                                .font(DeckDesign.font(9, weight: .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .glassEffect(.regular, in: Capsule())
                                .fixedSize()
                                .offset(y: -40)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
            }
        }
        .frame(width: 96, height: 96)
        .zIndex(1)
    }

    private func ringOrder(_ lhs: UsageRingDescriptor, _ rhs: UsageRingDescriptor) -> Bool {
        lhs.position == .outer && rhs.position == .inner
    }

    private func ringButton(_ descriptor: UsageRingDescriptor) -> some View {
        let size: CGFloat = descriptor.position == .outer ? 88 : 66
        let color = descriptor.accent == .shortWindow ? DeckDesign.windowCoral : Color.primary.opacity(0.92)
        let isSelected = descriptor.id == selectedKind
        return Button { onSelect(descriptor.id) } label: {
            ZStack {
                Circle().stroke(DeckDesign.ringTrack, lineWidth: 6)
                if descriptor.window.usedPercent > 0 {
                    Circle()
                        .trim(from: 0, to: min(descriptor.window.usedPercent / 100, 1))
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: size, height: size)
            .opacity(isSelected ? 1 : 0.5)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .deckInteractive(
            help: "Show the \(descriptor.window.windowDisplayName) in the gauge and menu bar"
        )
        .accessibilityLabel("Select \(descriptor.window.windowDisplayName)")
        .accessibilityValue("\(Int(descriptor.window.usedPercent.rounded())) percent")
    }
}

private struct UsageMetricRow: View {
    let descriptor: UsageRingDescriptor
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                    Text(descriptor.window.limitDisplayName)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    if let reset = descriptor.window.resetsAt {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("Resets \(reset, style: .relative)")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 6)
                    Text("\(Int(descriptor.window.usedPercent.rounded()))%")
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DeckDesign.ringTrack)
                        if descriptor.window.usedPercent > 0 {
                            Capsule()
                                .fill(accentColor)
                                .frame(width: proxy.size.width * min(descriptor.window.usedPercent / 100, 1))
                        }
                    }
                }
                .frame(height: 3)
            }
            .font(DeckDesign.font(11))
            .contentShape(Rectangle())
            .opacity(isSelected ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .deckInteractive(
            help: "Show the \(descriptor.window.windowDisplayName) in the gauge and menu bar",
            style: .row
        )
        .accessibilityLabel("Select \(descriptor.window.windowDisplayName)")
        .accessibilityValue("\(Int(descriptor.window.usedPercent.rounded())) percent")
    }

    private var accentColor: Color {
        descriptor.accent == .shortWindow ? DeckDesign.windowCoral : Color.primary.opacity(0.92)
    }
}

private enum AntigravityBarColor {
    static func forIndex(_ index: Int) -> Color {
        switch index {
        case 0: Color(red: 0.42, green: 0.72, blue: 0.91)
        case 1: Color(red: 0.61, green: 0.77, blue: 0.42)
        case 2: Color(red: 0.78, green: 0.56, blue: 0.79)
        case 3: Color(red: 0.93, green: 0.59, blue: 0.43)
        default: Color(red: 0.51, green: 0.57, blue: 0.91)
        }
    }
}

private struct AntigravityMetricRow: View {
    let descriptor: AntigravityMetricDescriptor
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(descriptor.id.kind == .fiveHour ? "5-hour limit" : "Weekly limit")
                        .foregroundStyle(isSelected || isReached ? color : .secondary)
                    Spacer(minLength: 8)
                    Text(valueLabel)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(isSelected || isReached ? color : .primary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DeckDesign.ringTrack)
                        if let window = descriptor.window, window.usedPercent > 0 {
                            Capsule()
                                .fill(color)
                                .frame(width: proxy.size.width * min(window.usedPercent / 100, 1))
                        }
                    }
                }
                .frame(height: 4)
                if let reset = descriptor.window?.resetsAt {
                    Text("Resets \(reset, style: .relative)")
                        .font(DeckDesign.font(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(DeckDesign.font(12))
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(color)
                        .frame(width: 2)
                        .padding(.leading, -7)
                }
            }
            .opacity(descriptor.window == nil ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(descriptor.window == nil)
        .deckInteractive(
            help: "Select \(descriptor.id.group.displayName) \(descriptor.id.kind == .fiveHour ? "5-hour" : "weekly") usage",
            style: .row
        )
        .accessibilityLabel("Select \(descriptor.id.group.displayName) \(descriptor.id.kind == .fiveHour ? "5-hour" : "weekly") usage")
        .accessibilityValue(valueLabel)
    }

    private var color: Color { AntigravityBarColor.forIndex(descriptor.colorIndex) }

    private var isReached: Bool { (descriptor.window?.usedPercent ?? -1) >= 100 }

    private var valueLabel: String {
        if let window = descriptor.window { return "\(Int(window.usedPercent.rounded()))%" }
        if case .disabled = descriptor.state { return "Disabled" }
        return "--"
    }
}
