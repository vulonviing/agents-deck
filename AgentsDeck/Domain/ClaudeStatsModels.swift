import Foundation

enum ClaudeStatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case allTime
    case lastSevenDays
    case lastThirtyDays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allTime: "All time"
        case .lastSevenDays: "Last 7 days"
        case .lastThirtyDays: "Last 30 days"
        }
    }
}

struct ClaudeDailyActivityBucket: Codable, Equatable, Sendable {
    let day: UsageCalendarDay
    let messageCount: Int64
    let sessionCount: Int64
    let toolCallCount: Int64
    let tokensByModel: [String: Int64]

    var totalTokens: Int64 {
        tokensByModel.values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }
}

struct ClaudeModelUsage: Codable, Equatable, Identifiable, Sendable {
    let modelID: String
    let inputTokens: Int64
    let outputTokens: Int64

    var id: String { modelID }

    var totalTokens: Int64 {
        let (sum, overflow) = inputTokens.addingReportingOverflow(outputTokens)
        return overflow ? .max : sum
    }
}

struct ClaudeStatsPeriodSummary: Codable, Equatable, Sendable {
    let totalTokens: Int64
    let totalSessions: Int64
    let totalMessages: Int64
    let totalToolCalls: Int64
    let activeDays: Int
    let spanDays: Int?
    let favoriteModelID: String?
    let mostActiveDay: UsageCalendarDay?
    let currentStreakDays: Int
    let longestStreakDays: Int
}

struct ClaudeStatsSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let computedThrough: UsageCalendarDay?
    let firstSessionAt: Date?
    let dailyBuckets: [ClaudeDailyActivityBucket]
    let modelUsage: [ClaudeModelUsage]
    let allTimeSummary: ClaudeStatsPeriodSummary
    let lastSevenDaysSummary: ClaudeStatsPeriodSummary
    let lastThirtyDaysSummary: ClaudeStatsPeriodSummary
    let longestSessionSeconds: Int64?
    let peakHour: Int?

    func summary(for period: ClaudeStatsPeriod) -> ClaudeStatsPeriodSummary {
        switch period {
        case .allTime: allTimeSummary
        case .lastSevenDays: lastSevenDaysSummary
        case .lastThirtyDays: lastThirtyDaysSummary
        }
    }
}

enum ClaudeStatsState: Equatable, Sendable {
    case waiting
    case available
    case stale
    case unavailable
    case failed(ProviderErrorCode)
}

enum ClaudeStatsRefresh: Equatable, Sendable {
    case available(ClaudeStatsSnapshot)
    case unavailable
    case failed(ProviderErrorCode)
}
