import Charts
import SwiftUI

struct ClaudeStatsActivityView: View {
    let state: ProviderViewState

    @State private var section: ClaudeStatsSection = .overview
    @State private var period: ClaudeStatsPeriod = .allTime

    private var stats: ClaudeStatsSnapshot? { state.claudeStats }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Claude Code activity")
                        .font(DeckDesign.font(12, weight: .medium))
                    Text(subtitle)
                        .font(DeckDesign.font(10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel
            }

            Picker("Claude activity section", selection: $section) {
                ForEach(ClaudeStatsSection.allCases) { section in
                    Text(section.label).tag(section)
                }
            }
            .pickerStyle(.segmented)

            if let stats {
                Picker("Claude activity period", selection: $period) {
                    ForEach(ClaudeStatsPeriod.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                switch section {
                case .overview:
                    ClaudeStatsOverview(stats: stats, period: period)
                case .models:
                    ClaudeStatsModelsView(stats: stats, period: period)
                }

                Text("Approximate local activity from this Mac only.")
                    .font(DeckDesign.font(9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(emptyMessage)
                    .font(DeckDesign.font(10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
        .deckCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local Claude Code activity")
    }

    private var subtitle: String {
        guard let stats else { return "Official Claude Code local stats cache" }
        return "Updated \(stats.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder
    private var statusLabel: some View {
        let descriptor = state.claudeStatsState.descriptor
        Label(descriptor.label, systemImage: descriptor.symbol)
            .font(DeckDesign.font(9, weight: .medium))
            .foregroundStyle(descriptor.color)
    }

    private var emptyMessage: String {
        switch state.claudeStatsState {
        case .waiting: "Waiting for local Claude Code activity."
        case .unavailable: "Local activity is unavailable until Claude Code creates its stats cache."
        case .failed: "Claude Code activity could not be read safely. Rate limits remain available."
        case .stale: "The last local activity snapshot is stale."
        case .available: "Local activity has not arrived yet."
        }
    }
}

private enum ClaudeStatsSection: String, CaseIterable, Identifiable {
    case overview
    case models

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private struct ClaudeStatsOverview: View {
    let stats: ClaudeStatsSnapshot
    let period: ClaudeStatsPeriod

    private var summary: ClaudeStatsPeriodSummary { stats.summary(for: period) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClaudeActivityHeatmap(buckets: stats.dailyBuckets)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    value("Favorite model", summary.favoriteModelID.map(ClaudeStatsPresentation.model) ?? "—")
                    value("Total tokens", ClaudeStatsPresentation.compact(summary.totalTokens))
                }
                GridRow {
                    value("Sessions", summary.totalSessions.formatted())
                    value("Active days", activeDays)
                }
                GridRow {
                    value("Most active day", summary.mostActiveDay.map(ClaudeStatsPresentation.day) ?? "—")
                    value("Current streak", "\(summary.currentStreakDays)d")
                }
                GridRow {
                    value("Longest streak", "\(summary.longestStreakDays)d")
                    value("Messages", summary.totalMessages.formatted())
                }
                if period == .allTime {
                    GridRow {
                        value(
                            "Longest session",
                            stats.longestSessionSeconds.map(ClaudeStatsPresentation.duration) ?? "—"
                        )
                        value(
                            "Peak hour",
                            stats.peakHour.map { String(format: "%02d:00–%02d:00", $0, ($0 + 1) % 24) } ?? "—"
                        )
                    }
                } else {
                    GridRow {
                        value("Tool calls", summary.totalToolCalls.formatted())
                        value("Average tokens/day", averageTokens)
                    }
                }
            }
        }
    }

    private var activeDays: String {
        guard let span = summary.spanDays else { return summary.activeDays.formatted() }
        return "\(summary.activeDays.formatted())/\(span.formatted())"
    }

    private var averageTokens: String {
        guard let span = summary.spanDays, span > 0 else { return "—" }
        return ClaudeStatsPresentation.compact(summary.totalTokens / Int64(span))
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DeckDesign.font(9))
                .foregroundStyle(.secondary)
            Text(text)
                .font(DeckDesign.font(12, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClaudeActivityHeatmap: View {
    let buckets: [ClaudeDailyActivityBucket]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .trailing)
    @State private var scrollGeometry = TokenActivityScrollGeometry.zero
    @State private var hovered: ClaudeHeatmapCell?

    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 2
    private let tooltipWidth: CGFloat = 220
    private var rows: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7)
    }

    var body: some View {
        let cells = heatmapCells
        let thresholds = quartiles
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                LazyHGrid(rows: rows, spacing: cellSpacing) {
                    ForEach(cells) { cell in
                        let isHovered = hovered?.id == cell.id
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(opacity(for: cell.messages, thresholds: thresholds)))
                            .frame(width: cellSize, height: cellSize)
                            .scaleEffect(isHovered && !reduceMotion ? 1.1 : 1)
                            .offset(y: isHovered && !reduceMotion ? -1 : 0)
                            .zIndex(isHovered ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
                            .onHover { active in
                                if active {
                                    hovered = cell
                                } else if hovered?.id == cell.id {
                                    hovered = nil
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
            } action: { _, value in
                scrollGeometry = value
            }
            .frame(height: 112)
            .onAppear { scrollPosition.scrollTo(edge: .trailing) }
            .overlay {
                GeometryReader { proxy in
                    if let hovered,
                       let index = cells.firstIndex(where: { $0.id == hovered.id }) {
                        let column = CGFloat(index / 7)
                        let contentX = column * (cellSize + cellSpacing) + cellSize / 2
                        let viewportX = contentX - scrollGeometry.clampedOffset
                        let x = min(
                            max(tooltipWidth / 2, viewportX),
                            max(tooltipWidth / 2, proxy.size.width - tooltipWidth / 2)
                        )
                        ClaudeStatsTooltip(cell: hovered)
                            .frame(width: tooltipWidth)
                            .position(x: x, y: index % 7 < 3 ? 88 : 24)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .allowsHitTesting(false)
            }

            ClaudeThinScrollBar(geometry: scrollGeometry) { offset in
                scrollPosition.scrollTo(x: offset)
            }
            .frame(height: 3)

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
        .frame(height: 145, alignment: .top)
        .accessibilityLabel("Claude activity for the last 12 months")
        .onDisappear { hovered = nil }
    }

    private var heatmapCells: [ClaudeHeatmapCell] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today),
              let firstDay = calendar.date(byAdding: .weekOfYear, value: -51, to: week.start)
        else { return [] }
        let values = Dictionary(uniqueKeysWithValues: buckets.map { ($0.day, $0) })
        return (0..<(52 * 7)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { return nil }
            let bucket = values[UsageCalendarDay(year: year, month: month, day: day)]
            return ClaudeHeatmapCell(
                date: date,
                messages: bucket?.messageCount ?? 0,
                sessions: bucket?.sessionCount ?? 0,
                toolCalls: bucket?.toolCallCount ?? 0,
                tokens: bucket?.totalTokens ?? 0
            )
        }
    }

    private var quartiles: [Int64] {
        let values = buckets.map(\.messageCount).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { values[min(values.count - 1, Int(Double(values.count) * $0))] }
    }

    private func opacity(for messages: Int64, thresholds: [Int64]) -> Double {
        guard messages > 0 else { return 0.07 }
        let level = thresholds.filter { messages > $0 }.count
        return 0.28 + Double(level) * 0.2
    }
}

private struct ClaudeStatsModelsView: View {
    let stats: ClaudeStatsSnapshot
    let period: ClaudeStatsPeriod

    @State private var hoveredDay: Date?

    private var buckets: [ClaudeDailyActivityBucket] {
        let all = stats.dailyBuckets
        guard period != .allTime else { return all }
        let count = period == .lastSevenDays ? 7 : 30
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        let end = stats.computedThrough?.date(in: calendar.timeZone) ?? Date()
        guard let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) else { return all }
        return all.filter { $0.day.date(in: calendar.timeZone).map { $0 >= start && $0 <= end } ?? false }
    }

    private var points: [ClaudeModelDayPoint] {
        var values: [ClaudeModelDayPoint] = []
        for bucket in buckets {
            guard let date = bucket.day.date() else { continue }
            for (modelID, tokens) in bucket.tokensByModel {
                values.append(ClaudeModelDayPoint(date: date, modelID: modelID, tokens: tokens))
            }
        }
        return values.sorted {
            $0.date == $1.date ? $0.modelID < $1.modelID : $0.date < $1.date
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if points.isEmpty {
                Text("No model token activity was provided for this period.")
                    .font(DeckDesign.font(10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 145, alignment: .center)
            } else {
                modelChart
                modelRows
            }
        }
    }

    private var modelChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(period == .allTime ? "Tokens per day · last 12 months" : "Tokens per day")
                .font(DeckDesign.font(9))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Tokens", point.tokens),
                        series: .value("Model", point.modelID)
                    )
                    .foregroundStyle(by: .value("Model", ClaudeStatsPresentation.model(point.modelID)))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
                }
                if let hoveredDay {
                    RuleMark(x: .value("Selected day", hoveredDay, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ClaudeModelTooltip(day: hoveredDay, points: points)
                                .frame(width: 220)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
            .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                guard let plotFrame = proxy.plotFrame else {
                                    hoveredDay = nil
                                    return
                                }
                                let frame = geometry[plotFrame]
                                guard frame.contains(location),
                                      let date = proxy.value(atX: location.x - frame.minX, as: Date.self)
                                else {
                                    hoveredDay = nil
                                    return
                                }
                                hoveredDay = nearestDay(to: date)
                            case .ended:
                                hoveredDay = nil
                            }
                        }
                }
            }
            .frame(height: 175)
            .accessibilityLabel("Claude model tokens per day")
            .onDisappear { hoveredDay = nil }
        }
    }

    private var modelRows: some View {
        let values = modelTotals
        return VStack(spacing: 5) {
            ForEach(values, id: \.modelID) { value in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ClaudeStatsPresentation.model(value.modelID))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if period == .allTime {
                        Text("In \(ClaudeStatsPresentation.compact(value.input))")
                            .foregroundStyle(.secondary)
                        Text("Out \(ClaudeStatsPresentation.compact(value.output))")
                            .foregroundStyle(.secondary)
                    }
                    Text(ClaudeStatsPresentation.compact(value.total))
                        .fontWeight(.medium)
                }
                .font(DeckDesign.font(9).monospacedDigit())
            }
        }
    }

    private var modelTotals: [(modelID: String, input: Int64, output: Int64, total: Int64)] {
        if period == .allTime {
            return stats.modelUsage.map { ($0.modelID, $0.inputTokens, $0.outputTokens, $0.totalTokens) }
        }
        var totals: [String: Int64] = [:]
        for point in points {
            let current = totals[point.modelID] ?? 0
            let (sum, overflow) = current.addingReportingOverflow(point.tokens)
            totals[point.modelID] = overflow ? .max : sum
        }
        return totals.map { ($0.key, 0, 0, $0.value) }.sorted {
            $0.total == $1.total ? $0.modelID < $1.modelID : $0.total > $1.total
        }
    }

    private func nearestDay(to date: Date) -> Date? {
        let days = Set(points.map(\.date))
        return days.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }
}

private struct ClaudeThinScrollBar: View {
    let geometry: TokenActivityScrollGeometry
    let onScroll: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.primary.opacity(0.38))
                    .frame(width: geometry.thumbWidth(in: width))
                    .offset(x: geometry.thumbOffset(in: width))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged {
                    onScroll(geometry.contentOffset(for: $0.location.x, in: width))
                }
            )
            .accessibilityElement()
            .accessibilityLabel("Claude activity timeline")
            .accessibilityValue("\(Int((geometry.progress * 100).rounded())) percent")
        }
    }
}

private struct ClaudeStatsTooltip: View {
    let cell: ClaudeHeatmapCell

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(TokenActivityPresentation.day(cell.date))
                .foregroundStyle(.secondary)
            row("Messages", cell.messages)
            row("Sessions", cell.sessions)
            row("Tool calls", cell.toolCalls)
            row("Tokens", cell.tokens)
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

    private func row(_ label: String, _ value: Int64) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value.formatted())
        }
    }
}

private struct ClaudeModelTooltip: View {
    let day: Date
    let points: [ClaudeModelDayPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(TokenActivityPresentation.day(day))
                .foregroundStyle(.secondary)
            ForEach(values, id: \.modelID) { value in
                HStack {
                    Text(ClaudeStatsPresentation.model(value.modelID))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(TokenActivityPresentation.exactTokens(value.tokens))
                }
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

    private var values: [ClaudeModelDayPoint] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        return points.filter { calendar.isDate($0.date, inSameDayAs: day) }.sorted {
            $0.tokens == $1.tokens ? $0.modelID < $1.modelID : $0.tokens > $1.tokens
        }
    }
}

private struct ClaudeHeatmapCell: Identifiable, Equatable {
    let date: Date
    let messages: Int64
    let sessions: Int64
    let toolCalls: Int64
    let tokens: Int64

    var id: Date { date }
    var accessibilityLabel: String {
        "\(date.formatted(date: .abbreviated, time: .omitted)): "
            + "\(messages.formatted()) messages, \(tokens.formatted()) tokens"
    }
}

private struct ClaudeModelDayPoint: Identifiable {
    let date: Date
    let modelID: String
    let tokens: Int64

    var id: String { "\(date.timeIntervalSince1970):\(modelID)" }
}

private enum ClaudeStatsPresentation {
    static func compact(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func duration(_ seconds: Int64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func day(_ day: UsageCalendarDay) -> String {
        guard let date = day.date() else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func model(_ modelID: String) -> String {
        modelID
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

private extension ClaudeStatsState {
    var descriptor: (label: String, symbol: String, color: Color) {
        switch self {
        case .waiting: ("Waiting", "clock", .secondary)
        case .available: ("Local", "desktopcomputer", DeckDesign.windowCoral)
        case .stale: ("Stale", "clock.badge.exclamationmark", DeckDesign.stale)
        case .unavailable: ("Unavailable", "minus", .secondary)
        case .failed: ("Error", "exclamationmark.triangle", .red)
        }
    }
}
