import Foundation

struct UsageCalendarDay: Codable, Equatable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    func date(in timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }
}

struct CodexTokenActivitySummary: Codable, Equatable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSeconds: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

struct CodexDailyTokenBucket: Codable, Equatable, Sendable {
    let day: UsageCalendarDay
    let tokens: Int64
}

struct CodexTokenActivitySnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let summary: CodexTokenActivitySummary
    /// `nil` means the provider did not supply history. An empty array is verified empty history.
    let dailyBuckets: [CodexDailyTokenBucket]?
}

struct CodexResetCreditsSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let availableCount: Int64
    /// Earliest future expiry among the detail rows the provider supplied.
    let nextProvidedExpiry: Date?
}

struct CodexAccountSnapshot: Codable, Equatable, Sendable {
    var tokenActivity: CodexTokenActivitySnapshot?
    var resetCredits: CodexResetCreditsSnapshot?

    static let empty = Self(tokenActivity: nil, resetCredits: nil)
}

enum CodexActivityState: Equatable, Sendable {
    case waiting
    case available
    case stale
    case unavailable
    case failed(ProviderErrorCode)
}

enum CodexTokenActivityRefresh: Equatable, Sendable {
    case notRequested
    case verified(CodexTokenActivitySnapshot)
    case unavailable
    case failed(ProviderErrorCode)
}

struct CodexSupplementalRefresh: Equatable, Sendable {
    let resetCredits: CodexResetCreditsSnapshot?
    let tokenActivity: CodexTokenActivityRefresh
}

enum ProviderSupplement: Equatable, Sendable {
    case codex(CodexSupplementalRefresh)
}
