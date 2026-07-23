import Charts
import SwiftUI

struct CodexAccountActivityView: View {
    let state: ProviderViewState
    @State private var mode: TokenActivityMode = .daily

    private var account: CodexAccountSnapshot? { state.codexAccount }

    var body: some View {
        tokenActivityCard
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Codex account activity")
    }

    private var tokenActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token activity")
                        .font(DeckDesign.font(12, weight: .medium))
                    Text(activitySubtitle)
                        .font(DeckDesign.font(10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                activityStatus
            }

            summary(account?.tokenActivity?.summary)

            if let activity = account?.tokenActivity {
                Picker("Token activity period", selection: $mode) {
                    ForEach(TokenActivityMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if let buckets = activity.dailyBuckets {
                    if buckets.isEmpty {
                        unavailableMessage("Codex reported no token activity for this period.")
                    } else {
                        TokenActivityChart(mode: mode, buckets: buckets)
                    }
                } else {
                    unavailableMessage("Daily token history was not provided by Codex.")
                }
            } else {
                unavailableMessage(activityEmptyMessage)
            }
        }
        .deckCard()
    }

    private func summary(_ summary: CodexTokenActivitySummary?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                summaryValue("Lifetime", summary?.lifetimeTokens.map(Self.compactNumber) ?? "—")
                summaryValue("Peak day", summary?.peakDailyTokens.map(Self.compactNumber) ?? "—")
            }
            GridRow {
                summaryValue("Streak", summary?.currentStreakDays.map { "\($0)d" } ?? "—")
                summaryValue("Longest task", summary?.longestRunningTurnSeconds.map(Self.duration) ?? "—")
            }
            GridRow {
                summaryValue(
                    "Limit reset credits",
                    account?.resetCredits.map { Self.compactNumber($0.availableCount) } ?? "—"
                )
                summaryValue(
                    "Next expiry",
                    account?.resetCredits?.nextProvidedExpiry?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "Not provided"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DeckDesign.font(9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(DeckDesign.font(13, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var activityStatus: some View {
        let descriptor = state.codexActivityState.descriptor
        Label(descriptor.label, systemImage: descriptor.symbol)
            .font(DeckDesign.font(9, weight: .medium))
            .foregroundStyle(descriptor.color)
    }

    private func unavailableMessage(_ message: String) -> some View {
        Text(message)
            .font(DeckDesign.font(10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
            .multilineTextAlignment(.center)
    }

    private var activitySubtitle: String {
        guard let capturedAt = account?.tokenActivity?.capturedAt else { return "Official Codex app-server" }
        return "Verified \(capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var activityEmptyMessage: String {
        switch state.codexActivityState {
        case .waiting: "Waiting for verified token activity."
        case .unavailable: "Token activity is unavailable in this Codex version or account."
        case .failed: "Codex could not refresh token activity. Rate limits remain available."
        case .stale: "The last token activity snapshot is stale."
        case .available: "Token activity has not arrived yet."
        }
    }

    private static func compactNumber(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private static func duration(_ seconds: Int64) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private enum TokenActivityMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private struct TokenActivityChart: View {
    static let chartHeight: CGFloat = 145

    let mode: TokenActivityMode
    let buckets: [CodexDailyTokenBucket]

    private var points: [TokenChartPoint] {
        TokenActivitySeries.weeklyPoints(from: buckets)
    }

    var body: some View {
        Group {
            switch mode {
            case .daily:
                TokenHeatmap(buckets: buckets)
            case .weekly:
                WeeklyTokenChart(points: points, cumulative: false)
            case .cumulative:
                WeeklyTokenChart(points: points, cumulative: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TokenHeatmap: View {
    let buckets: [CodexDailyTokenBucket]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .trailing)
    @State private var scrollGeometry = TokenActivityScrollGeometry.zero
    @State private var hoveredCell: TokenHeatmapCell?

    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 2
    private let tooltipWidth: CGFloat = 190
    private var rows: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7)
    }

    var body: some View {
        let cells = heatmapCells
        let maximum = max(1, cells.map(\.tokens).max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                LazyHGrid(rows: rows, spacing: cellSpacing) {
                    ForEach(cells) { cell in
                        let isHovered = hoveredCell?.id == cell.id
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(opacity(for: cell.tokens, maximum: maximum)))
                            .frame(width: cellSize, height: cellSize)
                            .scaleEffect(isHovered && !reduceMotion ? 1.1 : 1)
                            .offset(y: isHovered && !reduceMotion ? -1 : 0)
                            .zIndex(isHovered ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 0.14),
                                value: isHovered
                            )
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredCell = cell
                                } else if hoveredCell?.id == cell.id {
                                    hoveredCell = nil
                                }
                            }
                            .help(cell.accessibilityLabel)
                            .accessibilityLabel(cell.accessibilityLabel)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.trailing, for: .initialOffset)
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: TokenActivityScrollGeometry.self) { geometry in
                TokenActivityScrollGeometry(
                    contentOffset: geometry.contentOffset.x,
                    contentWidth: geometry.contentSize.width,
                    containerWidth: geometry.containerSize.width
                )
            } action: { _, newValue in
                scrollGeometry = newValue
            }
            .frame(height: 112)
            .onAppear {
                scrollPosition.scrollTo(edge: .trailing)
            }
            .overlay {
                GeometryReader { proxy in
                    if let hoveredCell,
                       let index = cells.firstIndex(where: { $0.id == hoveredCell.id }) {
                        let column = CGFloat(index / 7)
                        let contentX = column * (cellSize + cellSpacing) + cellSize / 2
                        let viewportX = contentX - scrollGeometry.clampedOffset
                        let clampedX = min(
                            max(tooltipWidth / 2, viewportX),
                            max(tooltipWidth / 2, proxy.size.width - tooltipWidth / 2)
                        )
                        let row = index % 7

                        TokenActivityTooltip(
                            title: TokenActivityPresentation.day(hoveredCell.date),
                            primaryLabel: nil,
                            primaryValue: TokenActivityPresentation.exactTokens(hoveredCell.tokens)
                        )
                        .frame(width: tooltipWidth)
                        .position(x: clampedX, y: row < 3 ? 88 : 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .allowsHitTesting(false)
            }

            ThinHorizontalScrollBar(geometry: scrollGeometry) { offset in
                scrollPosition.scrollTo(x: offset)
            }
            .frame(height: 4)

            HStack(spacing: 4) {
                Text("Less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.07 + Double(level) * 0.17))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text("More")
                Spacer()
                Text("Last 12 months")
            }
            .font(DeckDesign.font(9))
            .foregroundStyle(.secondary)
        }
        .frame(height: TokenActivityChart.chartHeight, alignment: .top)
        .accessibilityLabel("Daily token activity for the last 12 months")
        .onDisappear {
            hoveredCell = nil
        }
    }

    private var heatmapCells: [TokenHeatmapCell] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        guard let firstDay = calendar.date(byAdding: .day, value: -364, to: today) else { return [] }
        let values = Dictionary(uniqueKeysWithValues: buckets.map { ($0.day, $0.tokens) })
        return (0..<365).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { return nil }
            let key = UsageCalendarDay(year: year, month: month, day: day)
            return TokenHeatmapCell(date: date, tokens: values[key] ?? 0)
        }
    }

    private func opacity(for tokens: Int64, maximum: Int64) -> Double {
        guard tokens > 0 else { return 0.07 }
        return 0.22 + 0.66 * sqrt(Double(tokens) / Double(maximum))
    }
}

private struct WeeklyTokenChart: View {
    let points: [TokenChartPoint]
    let cumulative: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredPointID: Date?

    var body: some View {
        Chart(points) { point in
            let isHovered = hoveredPointID == point.id
            BarMark(
                x: .value("Week", point.weekStart, unit: .weekOfYear),
                y: .value(
                    cumulative ? "Running total" : "Tokens",
                    cumulative ? point.runningTotal : point.weeklyTokens
                )
            )
            .foregroundStyle(Color.primary.opacity(isHovered ? 0.92 : (cumulative ? 0.78 : 0.62)))
            .cornerRadius(2)
            .offset(y: isHovered && !reduceMotion ? -2 : 0)
            .annotation(
                position: .top,
                spacing: 4,
                overflowResolution: AnnotationOverflowResolution(
                    x: .fit(to: .chart),
                    y: .fit(to: .chart)
                )
            ) {
                if isHovered {
                    TokenActivityTooltip(
                        title: TokenActivityPresentation.period(
                            from: point.weekStart,
                            through: point.weekEnd
                        ),
                        primaryLabel: cumulative ? "Running total" : nil,
                        primaryValue: TokenActivityPresentation.exactTokens(
                            cumulative ? point.runningTotal : point.weeklyTokens
                        ),
                        secondaryLabel: cumulative ? "This week" : nil,
                        secondaryValue: cumulative
                            ? TokenActivityPresentation.exactTokens(point.weeklyTokens)
                            : nil
                    )
                    .frame(width: cumulative ? 220 : 190)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let tokenValue = value.as(Int64.self) {
                        Text(tokenValue.formatted(.number.notation(.compactName)))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plotFrame = proxy.plotFrame else {
                                hoveredPointID = nil
                                return
                            }
                            let frame = geometry[plotFrame]
                            guard frame.contains(location),
                                  let date = proxy.value(
                                      atX: location.x - frame.minX,
                                      as: Date.self
                                  )
                            else {
                                hoveredPointID = nil
                                return
                            }
                            hoveredPointID = points.min(by: {
                                abs($0.weekStart.timeIntervalSince(date))
                                    < abs($1.weekStart.timeIntervalSince(date))
                            })?.id
                        case .ended:
                            hoveredPointID = nil
                        }
                    }
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: hoveredPointID
        )
        .frame(height: TokenActivityChart.chartHeight)
        .accessibilityLabel(cumulative ? "Cumulative token activity by week" : "Weekly token activity")
        .onDisappear {
            hoveredPointID = nil
        }
    }
}

private struct ThinHorizontalScrollBar: View {
    let geometry: TokenActivityScrollGeometry
    let onScroll: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let thumbWidth = geometry.thumbWidth(in: trackWidth)
            let thumbOffset = geometry.thumbOffset(in: trackWidth)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(Color.primary.opacity(0.38))
                    .frame(width: thumbWidth)
                    .offset(x: thumbOffset)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScroll(geometry.contentOffset(for: value.location.x, in: trackWidth))
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Daily token activity timeline")
            .accessibilityValue("\(Int((geometry.progress * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onScroll(geometry.steppedOffset(forward: true))
                case .decrement:
                    onScroll(geometry.steppedOffset(forward: false))
                @unknown default:
                    break
                }
            }
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .right:
                    onScroll(geometry.steppedOffset(forward: true))
                case .left:
                    onScroll(geometry.steppedOffset(forward: false))
                default:
                    break
                }
            }
        }
    }
}

struct TokenActivityScrollGeometry: Equatable, Sendable {
    static let zero = Self(contentOffset: 0, contentWidth: 0, containerWidth: 0)

    let contentOffset: CGFloat
    let contentWidth: CGFloat
    let containerWidth: CGFloat

    var maximumOffset: CGFloat {
        max(0, contentWidth - containerWidth)
    }

    var clampedOffset: CGFloat {
        min(max(0, contentOffset), maximumOffset)
    }

    var progress: CGFloat {
        guard maximumOffset > 0 else { return 1 }
        return clampedOffset / maximumOffset
    }

    func thumbWidth(in trackWidth: CGFloat) -> CGFloat {
        guard trackWidth > 0, contentWidth > 0 else { return max(0, trackWidth) }
        let proportionalWidth = trackWidth * min(1, containerWidth / contentWidth)
        return min(trackWidth, max(24, proportionalWidth))
    }

    func thumbOffset(in trackWidth: CGFloat) -> CGFloat {
        max(0, trackWidth - thumbWidth(in: trackWidth)) * progress
    }

    func contentOffset(for trackLocation: CGFloat, in trackWidth: CGFloat) -> CGFloat {
        let travel = max(0, trackWidth - thumbWidth(in: trackWidth))
        guard travel > 0 else { return 0 }
        let thumbOrigin = min(max(0, trackLocation - thumbWidth(in: trackWidth) / 2), travel)
        return maximumOffset * (thumbOrigin / travel)
    }

    func steppedOffset(forward: Bool) -> CGFloat {
        let delta = max(containerWidth * 0.8, maximumOffset * 0.1)
        let proposed = clampedOffset + (forward ? delta : -delta)
        return min(max(0, proposed), maximumOffset)
    }
}

private struct TokenActivityTooltip: View {
    let title: String
    let primaryLabel: String?
    let primaryValue: String
    var secondaryLabel: String? = nil
    var secondaryValue: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(.secondary)

            tooltipValue(primaryLabel, primaryValue)

            if let secondaryValue {
                tooltipValue(secondaryLabel, secondaryValue)
            }
        }
        .font(DeckDesign.font(9, weight: .medium).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }

    @ViewBuilder
    private func tooltipValue(_ label: String?, _ value: String) -> some View {
        if let label {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
            }
        } else {
            Text(value)
        }
    }
}

enum TokenActivityPresentation {
    static func exactTokens(_ tokens: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        "\(tokens.formatted(.number.locale(locale))) tokens"
    }

    static func day(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func period(
        from start: Date,
        through end: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        "\(day(start, locale: locale, timeZone: timeZone)) – "
            + day(end, locale: locale, timeZone: timeZone)
    }
}

enum TokenActivitySeries {
    static func weeklyPoints(
        from buckets: [CodexDailyTokenBucket],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TokenChartPoint] {
        var grouped: [Date: (weekEnd: Date, tokens: Int64)] = [:]

        for bucket in buckets {
            guard let date = bucket.day.date(in: calendar.timeZone),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: date)
            else { continue }

            let current = grouped[interval.start]?.tokens ?? 0
            let (sum, overflow) = current.addingReportingOverflow(bucket.tokens)
            grouped[interval.start] = (
                weekEnd: interval.end.addingTimeInterval(-1),
                tokens: overflow ? .max : sum
            )
        }

        var runningTotal: Int64 = 0
        return grouped.keys.sorted().compactMap { weekStart in
            guard let group = grouped[weekStart] else { return nil }
            let (sum, overflow) = runningTotal.addingReportingOverflow(group.tokens)
            runningTotal = overflow ? .max : sum
            return TokenChartPoint(
                weekStart: weekStart,
                weekEnd: group.weekEnd,
                weeklyTokens: group.tokens,
                runningTotal: runningTotal
            )
        }
    }
}

struct TokenChartPoint: Identifiable, Equatable, Sendable {
    let weekStart: Date
    let weekEnd: Date
    let weeklyTokens: Int64
    let runningTotal: Int64

    var id: Date { weekStart }
}

private struct TokenHeatmapCell: Identifiable, Equatable {
    let date: Date
    let tokens: Int64
    var id: Date { date }
    var accessibilityLabel: String {
        "\(date.formatted(date: .abbreviated, time: .omitted)): \(tokens.formatted()) tokens"
    }
}

private extension CodexActivityState {
    var descriptor: (label: String, symbol: String, color: Color) {
        switch self {
        case .waiting: ("Waiting", "clock", .secondary)
        case .available: ("Verified", "checkmark", DeckDesign.connected)
        case .stale: ("Stale", "clock.badge.exclamationmark", DeckDesign.stale)
        case .unavailable: ("Unavailable", "minus", .secondary)
        case .failed: ("Error", "exclamationmark.triangle", .red)
        }
    }
}
