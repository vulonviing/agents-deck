import Foundation

enum AntigravityUsageParser {
    static func parse(_ data: Data, capturedAt: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= 64 * 1_024,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["status"] as? String == "SUCCESS",
              let report = envelope["response"] as? String,
              report.utf8.count <= 32 * 1_024
        else { throw ProviderBoundaryError.invalidPayload }

        var groups: [AntigravityQuotaGroup: [UsageWindowKind: QuotaWindowState]] = [:]
        for line in report.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4,
                  let group = group(for: fields[0]),
                  let kind = kind(for: fields[1], group: group),
                  groups[group]?[kind] == nil
            else { continue }

            if fields[2].localizedCaseInsensitiveCompare("disabled") == .orderedSame {
                groups[group, default: [:]][kind] = .disabled
                continue
            }
            guard fields[2].hasSuffix("%"),
                  let remaining = Double(fields[2].dropLast()),
                  remaining.isFinite, (0...100).contains(remaining)
            else { continue }
            let reset: Date?
            if fields[3].isEmpty {
                reset = nil
            } else {
                guard let parsed = parseDate(fields[3]),
                      UsageAlgorithms.validResetDate(epochSeconds: parsed.timeIntervalSince1970, now: capturedAt) != nil,
                      parsed >= capturedAt.addingTimeInterval(-60)
                else { continue }
                reset = parsed
            }
            groups[group, default: [:]][kind] = .available(UsageWindow(
                kind: kind,
                usedPercent: 100 - remaining,
                resetsAt: reset
            ))
        }
        guard !groups.isEmpty else { throw ProviderBoundaryError.invalidPayload }
        return UsageSnapshot(
            provider: .antigravity,
            capturedAt: capturedAt,
            source: .antigravityUsageCommand,
            windows: [:],
            billing: nil,
            groupedWindows: groups
        )
    }

    private static func group(for value: String) -> AntigravityQuotaGroup? {
        switch value.lowercased() {
        case "gemini models": .geminiModels
        case "claude and gpt models": .claudeAndGPTModels
        case "gemini 4 argon": .gemini4Argon
        default: nil
        }
    }

    private static func kind(for value: String, group: AntigravityQuotaGroup) -> UsageWindowKind? {
        switch value.lowercased() {
        case "weekly limit remaining": .sevenDay
        case "five hour limit remaining": .fiveHour
        case "gemini 4 argon weekly limit" where group == .gemini4Argon: .sevenDay
        default: nil
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
