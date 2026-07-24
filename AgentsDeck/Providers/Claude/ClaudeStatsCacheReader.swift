import Darwin
import Foundation

protocol ClaudeStatsReading: Sendable {
    func read(capturedAt: Date) throws -> ClaudeStatsSnapshot
}

enum ClaudeStatsCacheError: Error, Equatable {
    case unavailable
    case unsafeFile
    case tooLarge
    case invalidPayload

    var providerCode: ProviderErrorCode {
        switch self {
        case .unavailable: .fileAccess
        case .unsafeFile, .tooLarge: .fileAccess
        case .invalidPayload: .invalidPayload
        }
    }
}

struct ClaudeStatsCacheReader: ClaudeStatsReading, Sendable {
    private static let maximumSize = 2 * 1_024 * 1_024

    private let homeDirectory: URL
    private let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func read(capturedAt: Date = Date()) throws -> ClaudeStatsSnapshot {
        let descriptor = Darwin.open(
            try cacheURL().path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw ClaudeStatsCacheError.unavailable }
            throw ClaudeStatsCacheError.unsafeFile
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid()
        else {
            throw ClaudeStatsCacheError.unsafeFile
        }
        guard status.st_size >= 0, status.st_size <= Self.maximumSize else {
            throw ClaudeStatsCacheError.tooLarge
        }

        let data: Data
        do {
            data = try handle.read(upToCount: Self.maximumSize + 1) ?? Data()
        } catch {
            throw ClaudeStatsCacheError.unsafeFile
        }
        guard data.count <= Self.maximumSize else { throw ClaudeStatsCacheError.tooLarge }
        return try ClaudeStatsCacheParser.parse(data, capturedAt: capturedAt)
    }

    private func cacheURL() throws -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            guard configured.hasPrefix("/") else { throw ClaudeStatsCacheError.unsafeFile }
            let url = URL(filePath: configured, directoryHint: .isDirectory)
            return url.appending(path: "stats-cache.json")
        }
        return homeDirectory
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "stats-cache.json")
    }
}

enum ClaudeStatsCacheParser {
    private struct WireCache: Decodable {
        let version: Int
        let lastComputedDate: String?
        let dailyActivity: [WireDailyActivity]
        let dailyModelTokens: [WireDailyModelTokens]
        let modelUsage: [String: WireModelUsage]
        let totalSessions: Int64
        let totalMessages: Int64
        let longestSession: WireLongestSession?
        let firstSessionDate: String?
        let hourCounts: [String: Int64]?
    }

    private struct WireDailyActivity: Decodable {
        let date: String
        let messageCount: Int64
        let sessionCount: Int64
        let toolCallCount: Int64
    }

    private struct WireDailyModelTokens: Decodable {
        let date: String
        let tokensByModel: [String: Int64]
    }

    private struct WireModelUsage: Decodable {
        let inputTokens: Int64
        let outputTokens: Int64
    }

    private struct WireLongestSession: Decodable {
        let duration: Int64
        let timestamp: String?
    }

    private struct MutableDay {
        var messages: Int64 = 0
        var sessions: Int64 = 0
        var toolCalls: Int64 = 0
        var tokensByModel: [String: Int64] = [:]
    }

    static func parse(
        _ data: Data,
        capturedAt: Date = Date(),
        calendar inputCalendar: Calendar = .autoupdatingCurrent
    ) throws -> ClaudeStatsSnapshot {
        let wire: WireCache
        do {
            wire = try JSONDecoder().decode(WireCache.self, from: data)
        } catch {
            throw ClaudeStatsCacheError.invalidPayload
        }

        guard wire.version > 0,
              wire.totalSessions >= 0,
              wire.totalMessages >= 0
        else { throw ClaudeStatsCacheError.invalidPayload }

        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone
        let today = calendar.startOfDay(for: capturedAt)
        guard let earliestRetained = calendar.date(byAdding: .day, value: -364, to: today) else {
            throw ClaudeStatsCacheError.invalidPayload
        }

        var days: [UsageCalendarDay: MutableDay] = [:]
        for activity in wire.dailyActivity {
            guard activity.messageCount >= 0,
                  activity.sessionCount >= 0,
                  activity.toolCallCount >= 0,
                  let day = parseDay(activity.date),
                  let date = day.date(in: calendar.timeZone),
                  calendar.startOfDay(for: date) <= today
            else { throw ClaudeStatsCacheError.invalidPayload }
            var value = days[day] ?? MutableDay()
            value.messages = activity.messageCount
            value.sessions = activity.sessionCount
            value.toolCalls = activity.toolCallCount
            days[day] = value
        }

        for tokenDay in wire.dailyModelTokens {
            guard let day = parseDay(tokenDay.date),
                  let date = day.date(in: calendar.timeZone),
                  calendar.startOfDay(for: date) <= today
            else { throw ClaudeStatsCacheError.invalidPayload }
            var value = days[day] ?? MutableDay()
            for (modelID, tokens) in tokenDay.tokensByModel {
                guard isValidModelID(modelID), tokens >= 0 else {
                    throw ClaudeStatsCacheError.invalidPayload
                }
                value.tokensByModel[modelID] = tokens
            }
            days[day] = value
        }

        var allModelUsage: [ClaudeModelUsage] = []
        for (modelID, usage) in wire.modelUsage {
            guard isValidModelID(modelID), usage.inputTokens >= 0, usage.outputTokens >= 0 else {
                throw ClaudeStatsCacheError.invalidPayload
            }
            guard !usage.inputTokens.addingReportingOverflow(usage.outputTokens).overflow else {
                throw ClaudeStatsCacheError.invalidPayload
            }
            allModelUsage.append(ClaudeModelUsage(
                modelID: modelID,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            ))
        }
        allModelUsage.sort {
            if $0.totalTokens == $1.totalTokens { return $0.modelID < $1.modelID }
            return $0.totalTokens > $1.totalTokens
        }

        let computedThrough = try wire.lastComputedDate.map(validatedDay)
        let firstSessionAt = try wire.firstSessionDate.map(validatedTimestamp)
        let longestSessionSeconds: Int64?
        if let duration = wire.longestSession?.duration {
            guard duration >= 0 else { throw ClaudeStatsCacheError.invalidPayload }
            longestSessionSeconds = duration / 1_000
        } else {
            longestSessionSeconds = nil
        }
        if let timestamp = wire.longestSession?.timestamp {
            _ = try validatedTimestamp(timestamp)
        }

        let peakHour = try validatedPeakHour(wire.hourCounts)
        let allBuckets = days.map { day, value in
            ClaudeDailyActivityBucket(
                day: day,
                messageCount: value.messages,
                sessionCount: value.sessions,
                toolCallCount: value.toolCalls,
                tokensByModel: value.tokensByModel
            )
        }.sorted { $0.day < $1.day }

        let retainedBuckets = allBuckets.filter {
            guard let date = $0.day.date(in: calendar.timeZone) else { return false }
            let day = calendar.startOfDay(for: date)
            return day >= earliestRetained && day <= today
        }
        let summaryEnd = computedThrough?.date(in: calendar.timeZone).map {
            min(calendar.startOfDay(for: $0), today)
        } ?? today

        let allTimeSummary = try summary(
            buckets: allBuckets,
            rangeStart: firstSessionAt.map { calendar.startOfDay(for: $0) },
            rangeEnd: summaryEnd,
            allTimeModels: allModelUsage,
            totalSessions: wire.totalSessions,
            totalMessages: wire.totalMessages,
            calendar: calendar
        )
        let sevenStart = calendar.date(byAdding: .day, value: -6, to: summaryEnd)
        let thirtyStart = calendar.date(byAdding: .day, value: -29, to: summaryEnd)

        return ClaudeStatsSnapshot(
            capturedAt: capturedAt,
            computedThrough: computedThrough,
            firstSessionAt: firstSessionAt,
            dailyBuckets: retainedBuckets,
            modelUsage: allModelUsage,
            allTimeSummary: allTimeSummary,
            lastSevenDaysSummary: try summary(
                buckets: allBuckets,
                rangeStart: sevenStart,
                rangeEnd: summaryEnd,
                fixedSpanDays: 7,
                calendar: calendar
            ),
            lastThirtyDaysSummary: try summary(
                buckets: allBuckets,
                rangeStart: thirtyStart,
                rangeEnd: summaryEnd,
                fixedSpanDays: 30,
                calendar: calendar
            ),
            longestSessionSeconds: longestSessionSeconds,
            peakHour: peakHour
        )
    }

    private static func summary(
        buckets: [ClaudeDailyActivityBucket],
        rangeStart: Date?,
        rangeEnd: Date,
        fixedSpanDays: Int? = nil,
        allTimeModels: [ClaudeModelUsage]? = nil,
        totalSessions: Int64? = nil,
        totalMessages: Int64? = nil,
        calendar: Calendar
    ) throws -> ClaudeStatsPeriodSummary {
        let selected = buckets.filter { bucket in
            guard let date = bucket.day.date(in: calendar.timeZone) else { return false }
            let day = calendar.startOfDay(for: date)
            guard day <= rangeEnd else { return false }
            return rangeStart.map { day >= $0 } ?? true
        }

        var sessions: Int64 = 0
        var messages: Int64 = 0
        var toolCalls: Int64 = 0
        var modelTotals: [String: Int64] = [:]
        for bucket in selected {
            sessions = try adding(sessions, bucket.sessionCount)
            messages = try adding(messages, bucket.messageCount)
            toolCalls = try adding(toolCalls, bucket.toolCallCount)
            for (modelID, tokens) in bucket.tokensByModel {
                modelTotals[modelID] = try adding(modelTotals[modelID] ?? 0, tokens)
            }
        }

        if let allTimeModels {
            modelTotals = Dictionary(uniqueKeysWithValues: try allTimeModels.map {
                ($0.modelID, try adding($0.inputTokens, $0.outputTokens))
            })
        }
        let totalTokens = try modelTotals.values.reduce(0, adding)
        let activeDays = selected.filter { $0.messageCount > 0 }.count
        let activeSet = Set(selected.filter { $0.messageCount > 0 }.map(\.day))
        let streaks = streaks(activeDays: activeSet, rangeStart: rangeStart, rangeEnd: rangeEnd, calendar: calendar)
        let favorite = modelTotals.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }?.key
        let mostActive = selected.filter { $0.messageCount > 0 }.max {
            $0.messageCount == $1.messageCount ? $0.day < $1.day : $0.messageCount < $1.messageCount
        }?.day
        let spanDays: Int?
        if let fixedSpanDays {
            spanDays = fixedSpanDays
        } else if let rangeStart {
            spanDays = max(1, (calendar.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 0) + 1)
        } else {
            spanDays = nil
        }

        return ClaudeStatsPeriodSummary(
            totalTokens: totalTokens,
            totalSessions: totalSessions ?? sessions,
            totalMessages: totalMessages ?? messages,
            totalToolCalls: toolCalls,
            activeDays: activeDays,
            spanDays: spanDays,
            favoriteModelID: favorite,
            mostActiveDay: mostActive,
            currentStreakDays: streaks.current,
            longestStreakDays: streaks.longest
        )
    }

    private static func streaks(
        activeDays: Set<UsageCalendarDay>,
        rangeStart: Date?,
        rangeEnd: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        let sortedDates = activeDays.compactMap { $0.date(in: calendar.timeZone) }.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for date in sortedDates {
            if let previous,
               calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }

        var cursor = rangeEnd
        var current = 0
        let activeDates = Set(sortedDates.map { calendar.startOfDay(for: $0) })
        if !activeDates.contains(cursor),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
           activeDates.contains(yesterday) {
            cursor = yesterday
        }
        while activeDates.contains(cursor), rangeStart.map({ cursor >= $0 }) ?? true {
            current += 1
            guard let prior = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prior
        }
        return (current, longest)
    }

    private static func validatedDay(_ value: String) throws -> UsageCalendarDay {
        guard let day = parseDay(value) else { throw ClaudeStatsCacheError.invalidPayload }
        return day
    }

    private static func parseDay(_ value: String) -> UsageCalendarDay? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date).year == year,
              calendar.dateComponents([.year, .month, .day], from: date).month == month,
              calendar.dateComponents([.year, .month, .day], from: date).day == day
        else { return nil }
        return UsageCalendarDay(year: year, month: month, day: day)
    }

    private static func validatedTimestamp(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        throw ClaudeStatsCacheError.invalidPayload
    }

    private static func validatedPeakHour(_ values: [String: Int64]?) throws -> Int? {
        guard let values else { return nil }
        var parsed: [(hour: Int, count: Int64)] = []
        for (key, count) in values {
            guard let hour = Int(key), (0...23).contains(hour), count >= 0 else {
                throw ClaudeStatsCacheError.invalidPayload
            }
            parsed.append((hour, count))
        }
        return parsed.max {
            $0.count == $1.count ? $0.hour > $1.hour : $0.count < $1.count
        }?.hour
    }

    private static func isValidModelID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ClaudeStatsCacheError.invalidPayload }
        return sum
    }
}
