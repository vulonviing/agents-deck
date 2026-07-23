import Foundation

struct CodexRPCResponse: Decodable, Sendable {
    let id: Int?
    let result: JSONValue?
    let error: CodexRPCError?
    let method: String?
    let params: JSONValue?
}

struct CodexRPCError: Decodable, Sendable {
    let code: Int?
    let message: String?
}

enum CodexRateLimitParser {
    static func parse(_ response: JSONValue, now: Date = Date()) throws -> UsageSnapshot {
        try parseRefresh(response, now: now).snapshot
    }

    static func parseRefresh(_ response: JSONValue, now: Date = Date()) throws -> CodexRateLimitParseResult {
        guard let root = response.objectValue else {
            throw ProviderBoundaryError.invalidPayload
        }
        let snapshotObject = preferredSnapshot(in: root)
        guard let snapshotObject else { throw ProviderBoundaryError.invalidPayload }

        var windows: [UsageWindowKind: UsageWindow] = [:]
        if let primary = snapshotObject["primary"]?.objectValue,
           let parsed = try parseWindow(primary, fallbackKind: .fiveHour, now: now) {
            windows[parsed.kind] = parsed
        }
        if let secondary = snapshotObject["secondary"]?.objectValue,
           let parsed = try parseWindow(secondary, fallbackKind: .sevenDay, now: now) {
            windows[parsed.kind] = parsed
        }
        guard !windows.isEmpty else { throw ProviderBoundaryError.invalidPayload }

        let billing = parseBilling(snapshotObject, now: now)
        let snapshot = UsageSnapshot(
            provider: .codex,
            capturedAt: now,
            source: .codexAppServer,
            windows: windows,
            billing: billing
        )
        return CodexRateLimitParseResult(
            snapshot: snapshot,
            resetCredits: try parseResetCredits(root["rateLimitResetCredits"], now: now)
        )
    }

    private static func preferredSnapshot(in root: [String: JSONValue]) -> [String: JSONValue]? {
        if let byID = root["rateLimitsByLimitId"]?.objectValue {
            if let codex = byID["codex"]?.objectValue { return codex }
            if let identified = byID.values.compactMap(\.objectValue).first(where: {
                $0["limitId"]?.stringValue?.lowercased() == "codex"
            }) { return identified }
            if byID.count == 1 { return byID.values.first?.objectValue }
        }
        return root["rateLimits"]?.objectValue
    }

    private static func parseWindow(
        _ object: [String: JSONValue],
        fallbackKind: UsageWindowKind,
        now: Date
    ) throws -> UsageWindow? {
        guard let rawPercentage = object["usedPercent"]?.doubleValue else { return nil }
        let percentage = try UsageAlgorithms.normalizedPercentage(rawPercentage)
        let duration = try UsageAlgorithms.normalizedDurationMinutes(
            object["windowDurationMins"]?.intValue
        ) ?? fallbackKind.defaultDurationMinutes
        return UsageWindow(
            kind: fallbackKind,
            usedPercent: percentage,
            resetsAt: UsageAlgorithms.validResetDate(
                epochSeconds: object["resetsAt"]?.doubleValue,
                now: now
            ),
            durationMinutes: duration
        )
    }

    private static func parseBilling(
        _ snapshot: [String: JSONValue],
        now: Date
    ) -> ProviderBillingValue? {
        if let individualLimit = snapshot["individualLimit"]?.objectValue,
           let used = validatedNumericDisplay(individualLimit["used"]?.stringValue),
           let limit = validatedNumericDisplay(individualLimit["limit"]?.stringValue),
           let remainingPercent = individualLimit["remainingPercent"]?.intValue,
           (0...100).contains(remainingPercent) {
            return .monthlyCreditUsage(
                used: used,
                limit: limit,
                remainingPercent: remainingPercent,
                resetsAt: UsageAlgorithms.validResetDate(
                    epochSeconds: individualLimit["resetsAt"]?.doubleValue,
                    now: now
                )
            )
        }

        let credits = snapshot["credits"]?.objectValue
        guard let credits, credits["hasCredits"]?.boolValue == true else { return nil }
        if credits["unlimited"]?.boolValue == true { return .unlimitedCredits }
        guard let balance = validatedNumericDisplay(credits["balance"]?.stringValue) else { return nil }
        return .creditBalance(balance)
    }

    private static func validatedNumericDisplay(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 64,
              Decimal(string: value.replacingOccurrences(of: ",", with: ".")) != nil,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789.,- ").contains($0)
              })
        else { return nil }
        return value
    }

    private static func parseResetCredits(
        _ value: JSONValue?,
        now: Date
    ) throws -> CodexResetCreditsSnapshot? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue,
              let availableCount = object["availableCount"]?.int64Value,
              availableCount >= 0
        else { throw ProviderBoundaryError.invalidPayload }

        let expiries: [Date]
        switch object["credits"] {
        case nil, .some(.null):
            expiries = []
        case let .some(.array(values)):
            expiries = values.compactMap { value in
                guard let credit = value.objectValue,
                      credit["status"]?.stringValue == "available",
                      credit["resetType"]?.stringValue == "codexRateLimits",
                      let expiry = UsageAlgorithms.validResetDate(
                          epochSeconds: credit["expiresAt"]?.doubleValue,
                          now: now
                      ),
                      expiry > now
                else { return nil }
                return expiry
            }
        default:
            throw ProviderBoundaryError.invalidPayload
        }

        return CodexResetCreditsSnapshot(
            capturedAt: now,
            availableCount: availableCount,
            nextProvidedExpiry: expiries.min()
        )
    }
}

struct CodexRateLimitParseResult: Equatable, Sendable {
    let snapshot: UsageSnapshot
    let resetCredits: CodexResetCreditsSnapshot?
}
