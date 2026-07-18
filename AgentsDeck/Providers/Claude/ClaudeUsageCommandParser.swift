import Foundation

enum ClaudeUsageCommandParser {
    private struct WindowLabels {
        let kind: UsageWindowKind
        let labels: [String]
    }

    private static let windowLabels = [
        WindowLabels(kind: .fiveHour, labels: ["current session", "5-hour limit", "5 hour limit"]),
        WindowLabels(
            kind: .sevenDay,
            labels: ["current week (all models)", "current week", "7-day limit", "7 day limit"]
        ),
    ]

    static func parse(_ data: Data, capturedAt: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= 262_144 else { throw ProviderBoundaryError.messageTooLarge }
        return try parse(String(decoding: data, as: UTF8.self), capturedAt: capturedAt)
    }

    static func parse(_ rawText: String, capturedAt: Date = Date()) throws -> UsageSnapshot {
        let text = sanitizedText(rawText)
        guard !text.isEmpty,
              !text.localizedCaseInsensitiveContains("not logged in"),
              !text.localizedCaseInsensitiveContains("login required"),
              !text.localizedCaseInsensitiveContains("could not load usage"),
              !text.localizedCaseInsensitiveContains("loading usage")
        else { throw ProviderBoundaryError.invalidPayload }

        let lowercase = text.lowercased()
        var windows: [UsageWindowKind: UsageWindow] = [:]
        for labels in windowLabels {
            guard let section = section(for: labels, in: text, lowercase: lowercase),
                  let window = try parseWindow(section, kind: labels.kind, capturedAt: capturedAt)
            else { continue }
            windows[labels.kind] = window
        }

        guard !windows.isEmpty else { throw ProviderBoundaryError.invalidPayload }
        return UsageSnapshot(
            provider: .claude,
            capturedAt: capturedAt,
            source: .claudeUsageCommand,
            windows: windows,
            billing: nil
        )
    }

    private static func section(
        for target: WindowLabels,
        in text: String,
        lowercase: String
    ) -> String? {
        let starts = target.labels.compactMap { lowercase.range(of: $0, options: .backwards)?.lowerBound }
        guard let start = starts.max() else { return nil }

        let laterLabels = windowLabels
            .flatMap(\.labels)
            .filter { !target.labels.contains($0) }
            .compactMap { label -> String.Index? in
                guard let range = lowercase.range(of: label, range: start..<lowercase.endIndex),
                      range.lowerBound > start
                else { return nil }
                return range.lowerBound
            }
        let end = laterLabels.min() ?? text.endIndex
        return String(text[start..<end].prefix(2_000))
    }

    private static func parseWindow(
        _ section: String,
        kind: UsageWindowKind,
        capturedAt: Date
    ) throws -> UsageWindow? {
        guard let percentage = firstNumber(in: section, pattern: #"(\d{1,3}(?:[\.,]\d+)?)\s*%"#) else {
            return nil
        }
        let lower = section.lowercased()
        let rawUsed = lower.contains("remaining") || lower.contains("% left")
            ? 100 - percentage
            : percentage
        let used = try UsageAlgorithms.normalizedPercentage(rawUsed)
        return UsageWindow(
            kind: kind,
            usedPercent: used,
            resetsAt: resetDate(in: section, capturedAt: capturedAt),
            durationMinutes: kind.defaultDurationMinutes
        )
    }

    private static func resetDate(in section: String, capturedAt: Date) -> Date? {
        let lower = section.lowercased()
        guard lower.contains("reset") else { return nil }

        let units: [(String, TimeInterval)] = [
            (#"(\d+)\s*(?:days?|d)\b"#, 86_400),
            (#"(\d+)\s*(?:hours?|hrs?|hr|h)\b"#, 3_600),
            (#"(\d+)\s*(?:minutes?|mins?|min|m)\b"#, 60),
            (#"(\d+)\s*(?:seconds?|secs?|sec|s)\b"#, 1),
        ]
        var relative: TimeInterval = 0
        for (pattern, multiplier) in units {
            if let value = firstNumber(in: lower, pattern: pattern) {
                relative += value * multiplier
            }
        }
        if relative > 0, relative <= 8 * 24 * 60 * 60 {
            return capturedAt.addingTimeInterval(relative)
        }

        guard let resetText = (firstCapture(
            in: section,
            pattern: #"(?i)resets?\s*(?:at|on)?\s*[:·\-]?\s*([^\n]{3,80})"#
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if let isoDate = ISO8601DateFormatter().date(from: resetText) {
            return validatedReset(isoDate, capturedAt: capturedAt)
        }

        let displayTimeZonePattern = #"\s*\([^\)\n]{1,64}\)\s*$"#
        let localResetText: String
        if let expression = try? NSRegularExpression(pattern: displayTimeZonePattern) {
            localResetText = expression.stringByReplacingMatches(
                in: resetText,
                range: NSRange(resetText.startIndex..., in: resetText),
                withTemplate: ""
            )
        } else {
            localResetText = resetText
        }

        if let timeOnlyReset = timeOnlyResetDate(from: localResetText, capturedAt: capturedAt) {
            return timeOnlyReset
        }

        let formats = [
            "MMM d, yyyy 'at' h:mm a",
            "MMM d yyyy 'at' h:mm a",
            "MMM d 'at' h:mm a",
            "MMM d, yyyy h:mm a",
            "MMM d h:mm a",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            formatter.defaultDate = capturedAt
            guard var date = formatter.date(from: resetText) else { continue }
            if !format.contains("yyyy"), date < capturedAt.addingTimeInterval(-24 * 60 * 60),
               let nextYear = Calendar.current.date(byAdding: .year, value: 1, to: date) {
                date = nextYear
            }
            if let validated = validatedReset(date, capturedAt: capturedAt) { return validated }
        }
        return nil
    }

    private static func timeOnlyResetDate(from text: String, capturedAt: Date) -> Date? {
        let formats = ["h:mma", "h:mm a", "ha", "h a", "HH:mm"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            formatter.defaultDate = capturedAt
            formatter.isLenient = false
            guard let parsed = formatter.date(from: text),
                  let candidateToday = calendar.date(
                    bySettingHour: calendar.component(.hour, from: parsed),
                    minute: calendar.component(.minute, from: parsed),
                    second: 0,
                    of: capturedAt
                  )
            else { continue }

            let candidate: Date
            if candidateToday < capturedAt.addingTimeInterval(-60) {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: candidateToday) else {
                    continue
                }
                candidate = nextDay
            } else {
                candidate = candidateToday
            }
            if let validated = validatedReset(candidate, capturedAt: capturedAt) { return validated }
        }
        return nil
    }

    private static func validatedReset(_ date: Date, capturedAt: Date) -> Date? {
        let earliest = capturedAt.addingTimeInterval(-60)
        let latest = capturedAt.addingTimeInterval(8 * 24 * 60 * 60)
        return (earliest...latest).contains(date) ? date : nil
    }

    private static func firstNumber(in text: String, pattern: String) -> Double? {
        firstCapture(in: text, pattern: pattern)
            .map { $0.replacingOccurrences(of: ",", with: ".") }
            .flatMap(Double.init)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func sanitizedText(_ rawText: String) -> String {
        var result = rawText.replacingOccurrences(of: "\r", with: "\n")
        let patterns = [
            #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#,
            #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            #"[\u0000-\u0008\u000B\u000C\u000E-\u001A\u001C-\u001F]"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ClaudeVerifiedResetCache {
    private struct Entry {
        let reset: Date
        let durationMinutes: Int
    }

    private var entries: [UsageWindowKind: Entry] = [:]

    mutating func merge(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        var windows = snapshot.windows
        let latestAllowedReset = snapshot.capturedAt.addingTimeInterval(8 * 24 * 60 * 60)

        for kind in UsageWindowKind.allCases {
            guard let window = windows[kind] else { continue }

            if let reset = window.resetsAt {
                if reset > snapshot.capturedAt, reset <= latestAllowedReset {
                    entries[kind] = Entry(reset: reset, durationMinutes: window.durationMinutes)
                } else {
                    entries[kind] = nil
                }
                continue
            }

            guard let entry = entries[kind],
                  entry.durationMinutes == window.durationMinutes,
                  entry.reset > snapshot.capturedAt,
                  entry.reset <= latestAllowedReset
            else {
                if let entry = entries[kind], entry.reset <= snapshot.capturedAt {
                    entries[kind] = nil
                }
                continue
            }
            windows[kind] = UsageWindow(
                kind: window.kind,
                usedPercent: window.usedPercent,
                resetsAt: entry.reset,
                durationMinutes: window.durationMinutes
            )
        }

        return UsageSnapshot(
            provider: snapshot.provider,
            capturedAt: snapshot.capturedAt,
            source: snapshot.source,
            windows: windows,
            billing: snapshot.billing
        )
    }

    mutating func reset() {
        entries.removeAll()
    }
}
