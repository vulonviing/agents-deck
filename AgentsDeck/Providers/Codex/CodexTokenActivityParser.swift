import Foundation

enum CodexTokenActivityParser {
    private static let maximumRawBuckets = 2_000

    static func parse(_ response: JSONValue, now: Date = Date()) throws -> CodexTokenActivitySnapshot {
        guard let root = response.objectValue,
              let summaryObject = root["summary"]?.objectValue
        else { throw ProviderBoundaryError.invalidPayload }

        let summary = try CodexTokenActivitySummary(
            lifetimeTokens: nonnegativeOptional(summaryObject["lifetimeTokens"]),
            peakDailyTokens: nonnegativeOptional(summaryObject["peakDailyTokens"]),
            longestRunningTurnSeconds: nonnegativeOptional(summaryObject["longestRunningTurnSec"]),
            currentStreakDays: nonnegativeOptional(summaryObject["currentStreakDays"]),
            longestStreakDays: nonnegativeOptional(summaryObject["longestStreakDays"])
        )

        let buckets: [CodexDailyTokenBucket]?
        switch root["dailyUsageBuckets"] {
        case nil, .some(.null):
            buckets = nil
        case let .some(.array(values)):
            guard values.count <= maximumRawBuckets else {
                throw ProviderBoundaryError.messageTooLarge
            }
            buckets = try normalizedBuckets(values, now: now)
        default:
            throw ProviderBoundaryError.invalidPayload
        }

        return CodexTokenActivitySnapshot(capturedAt: now, summary: summary, dailyBuckets: buckets)
    }

    private static func nonnegativeOptional(_ value: JSONValue?) throws -> Int64? {
        guard let value, value != .null else { return nil }
        guard let integer = value.int64Value, integer >= 0 else {
            throw ProviderBoundaryError.invalidPayload
        }
        return integer
    }

    private static func normalizedBuckets(
        _ values: [JSONValue],
        now: Date
    ) throws -> [CodexDailyTokenBucket] {
        let timeZone = TimeZone.autoupdatingCurrent
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -364, to: today) else {
            throw ProviderBoundaryError.invalidPayload
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            throw ProviderBoundaryError.invalidPayload
        }

        var tokensByDay: [UsageCalendarDay: Int64] = [:]
        for value in values {
            guard let object = value.objectValue,
                  let rawDay = object["startDate"]?.stringValue,
                  let day = parseDay(rawDay),
                  let date = day.date(in: timeZone),
                  date >= cutoff,
                  date < tomorrow,
                  let rawTokens = object["tokens"]?.int64Value,
                  rawTokens >= 0
            else { continue }

            let current = tokensByDay[day] ?? 0
            let (sum, overflow) = current.addingReportingOverflow(rawTokens)
            guard !overflow else { throw ProviderBoundaryError.invalidPayload }
            tokensByDay[day] = sum
        }

        return tokensByDay
            .map { CodexDailyTokenBucket(day: $0.key, tokens: $0.value) }
            .sorted { $0.day < $1.day }
    }

    private static func parseDay(_ value: String) -> UsageCalendarDay? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }

        let result = UsageCalendarDay(year: year, month: month, day: day)
        guard let date = result.date(in: .gmt) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else { return nil }
        return result
    }
}
