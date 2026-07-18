import Foundation

enum ClaudeSessionMetadataParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> SessionConfigurationSnapshot {
        guard data.count <= 64 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let modelID = clean(model["id"], limit: 128)
        else { throw ProviderBoundaryError.invalidPayload }

        let capturedAt = captureDate(root["captured_at"], now: now) ?? now
        let effort = (root["effort"] as? [String: Any]).flatMap { clean($0["level"], limit: 32) }
        let agentName = (root["agent"] as? [String: Any]).flatMap { clean($0["name"], limit: 128) }
        let thinking = (root["thinking"] as? [String: Any])?["enabled"] as? Bool
        return SessionConfigurationSnapshot(
            provider: .claude,
            capturedAt: capturedAt,
            source: .claudeStatusLine,
            modelID: modelID,
            modelDisplayName: clean(model["display_name"], limit: 128),
            effort: effort,
            thinkingEnabled: thinking,
            agentName: agentName
        )
    }

    private static func clean(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func captureDate(_ value: Any?, now: Date) -> Date? {
        let seconds: Double?
        if let number = value as? NSNumber { seconds = number.doubleValue }
        else if let string = value as? String { seconds = Double(string) }
        else { seconds = nil }
        guard let seconds else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        guard date >= Date(timeIntervalSince1970: 1_577_836_800),
              date <= now.addingTimeInterval(5 * 60)
        else { return nil }
        return date
    }
}
