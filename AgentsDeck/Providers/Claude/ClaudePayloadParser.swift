import Foundation

enum ClaudePayloadParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any]
        else { throw ProviderBoundaryError.invalidPayload }

        let capturedAt = parseCaptureDate(root["captured_at"], now: now) ?? now
        var windows: [UsageWindowKind: UsageWindow] = [:]
        if let window = try parseWindow(limits["five_hour"], kind: .fiveHour, now: now) {
            windows[.fiveHour] = window
        }
        if let window = try parseWindow(limits["seven_day"], kind: .sevenDay, now: now) {
            windows[.sevenDay] = window
        }
        guard !windows.isEmpty else { throw ProviderBoundaryError.invalidPayload }

        let billing: ProviderBillingValue?
        if let cost = decimal(root["session_cost_usd"]), cost >= 0 {
            billing = .sessionCost(cost)
        } else {
            billing = nil
        }

        return UsageSnapshot(
            provider: .claude,
            capturedAt: capturedAt,
            source: .claudeStatusLine,
            windows: windows,
            billing: billing
        )
    }

    private static func parseWindow(
        _ value: Any?,
        kind: UsageWindowKind,
        now: Date
    ) throws -> UsageWindow? {
        guard let object = value as? [String: Any],
              let rawPercentage = double(object["used_percentage"])
        else { return nil }
        let percentage = try UsageAlgorithms.normalizedPercentage(rawPercentage)
        return UsageWindow(
            kind: kind,
            usedPercent: percentage,
            resetsAt: parseDate(object["resets_at"], now: now),
            durationMinutes: kind.defaultDurationMinutes
        )
    }

    private static func parseDate(_ value: Any?, now: Date) -> Date? {
        if let seconds = double(value) {
            return UsageAlgorithms.validResetDate(epochSeconds: seconds, now: now)
        }
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) {
                let earliest = now.addingTimeInterval(-8 * 24 * 60 * 60)
                let latest = now.addingTimeInterval(370 * 24 * 60 * 60)
                return (earliest...latest).contains(date) ? date : nil
            }
        }
        return nil
    }

    private static func parseCaptureDate(_ value: Any?, now: Date) -> Date? {
        let date: Date?
        if let seconds = double(value) {
            date = Date(timeIntervalSince1970: seconds)
        } else if let string = value as? String {
            date = ISO8601DateFormatter().date(from: string)
        } else {
            date = nil
        }
        guard let date,
              date >= Date(timeIntervalSince1970: 1_577_836_800),
              date <= now.addingTimeInterval(5 * 60)
        else { return nil }
        return date
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return number.decimalValue }
        if let string = value as? String { return Decimal(string: string) }
        return nil
    }
}
