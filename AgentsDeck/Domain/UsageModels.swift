import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

}

enum UsageWindowKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case sevenDay

    var id: String { rawValue }

    var defaultDurationMinutes: Int {
        switch self {
        case .fiveHour: 300
        case .sevenDay: 10_080
        }
    }
}

enum UsageSource: String, Codable, Sendable {
    case claudeStatusLine
    case claudeUsageCommand
    case codexAppServer
}

struct UsageWindow: Codable, Equatable, Sendable {
    let kind: UsageWindowKind
    let usedPercent: Double
    let resetsAt: Date?
    let durationMinutes: Int

    init(
        kind: UsageWindowKind,
        usedPercent: Double,
        resetsAt: Date?,
        durationMinutes: Int? = nil
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes ?? kind.defaultDurationMinutes
    }

    var displayName: String { Self.durationLabel(minutes: durationMinutes, compact: false) }
    var compactDurationLabel: String { Self.durationLabel(minutes: durationMinutes, compact: true) }
    var limitDisplayName: String { "\(Self.compoundDurationLabel(minutes: durationMinutes)) limit" }
    var windowDisplayName: String { "\(Self.compoundDurationLabel(minutes: durationMinutes)) window" }
    var isShortWindow: Bool { durationMinutes < UsageWindowKind.sevenDay.defaultDurationMinutes }

    private static func durationLabel(minutes: Int, compact: Bool) -> String {
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return compact ? "\(days)d" : "\(days) \(days == 1 ? "day" : "days")"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return compact ? "\(hours)h" : "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return compact ? "\(minutes)m" : "\(minutes) min"
    }

    private static func compoundDurationLabel(minutes: Int) -> String {
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

enum BillingKind: String, Codable, Sendable {
    case sessionCost
    case creditBalance
    case unlimitedCredits
    case monthlyCreditUsage
}

struct ProviderBillingValue: Codable, Equatable, Sendable {
    let kind: BillingKind
    let decimalValue: Decimal?
    let currencyCode: String?
    let providerDisplayValue: String?
    let limitDisplayValue: String?
    let remainingPercent: Int?
    let resetsAt: Date?

    static func sessionCost(_ value: Decimal, currencyCode: String = "USD") -> Self {
        Self(
            kind: .sessionCost,
            decimalValue: value,
            currencyCode: currencyCode,
            providerDisplayValue: nil,
            limitDisplayValue: nil,
            remainingPercent: nil,
            resetsAt: nil
        )
    }

    static func creditBalance(_ value: String) -> Self {
        Self(
            kind: .creditBalance,
            decimalValue: Decimal(string: value),
            currencyCode: nil,
            providerDisplayValue: value,
            limitDisplayValue: nil,
            remainingPercent: nil,
            resetsAt: nil
        )
    }

    static func monthlyCreditUsage(
        used: String,
        limit: String,
        remainingPercent: Int,
        resetsAt: Date?
    ) -> Self {
        Self(
            kind: .monthlyCreditUsage,
            decimalValue: Decimal(string: used),
            currencyCode: nil,
            providerDisplayValue: used,
            limitDisplayValue: limit,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt
        )
    }

    static let unlimitedCredits = Self(
        kind: .unlimitedCredits,
        decimalValue: nil,
        currencyCode: nil,
        providerDisplayValue: "Unlimited",
        limitDisplayValue: nil,
        remainingPercent: nil,
        resetsAt: nil
    )
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let provider: ProviderID
    let capturedAt: Date
    let source: UsageSource
    let windows: [UsageWindowKind: UsageWindow]
    let billing: ProviderBillingValue?

    subscript(kind: UsageWindowKind) -> UsageWindow? {
        windows[kind]
    }

    var sortedWindows: [UsageWindow] {
        windows.values.sorted {
            if $0.durationMinutes == $1.durationMinutes { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.durationMinutes < $1.durationMinutes
        }
    }

    var preferredGaugeWindow: UsageWindow? { sortedWindows.first }

    var shortWindow: UsageWindow? {
        sortedWindows.first(where: \.isShortWindow)
    }
}

enum ProviderErrorCode: String, Codable, Equatable, Sendable {
    case executableMissing
    case authenticationRequired
    case consentRequired
    case invalidPayload
    case unsupportedProtocol
    case processFailed
    case timedOut
    case settingsMalformed
    case fileAccess
    case retryPaused
    case unknown
}

enum ProviderConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case needsLogin
    case needsConsent
    case waiting
    case connected
    case stale
    case unavailable
    case failed(ProviderErrorCode)

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .needsLogin: "Login required"
        case .needsConsent: "Permission required"
        case .waiting: "Waiting for data"
        case .connected: "Connected"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        case .failed: "Error"
        }
    }
}

struct HistoryPoint: Identifiable, Equatable, Sendable {
    let id: UUID
    let provider: ProviderID
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
    let windowKind: UsageWindowKind
    let durationMinutes: Int
}

struct ProviderViewState: Equatable, Sendable {
    let provider: ProviderID
    var connection: ProviderConnectionState = .disconnected
    var refreshID: UUID?
    var snapshot: UsageSnapshot?
    var billing: ProviderBillingValue?
    var billingCapturedAt: Date?
    var executableVersion: String?
    var restartCount = 0
    var bridgeInstalled = false
    var claudeStats: ClaudeStatsSnapshot?
    var claudeStatsState: ClaudeStatsState = .waiting
    var codexAccount: CodexAccountSnapshot?
    var codexActivityState: CodexActivityState = .waiting

    static func empty(_ provider: ProviderID) -> Self {
        Self(provider: provider)
    }

    var isRefreshing: Bool { refreshID != nil }
}

struct AppViewState: Equatable, Sendable {
    var providers: [ProviderID: ProviderViewState] = Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.map { ($0, .empty($0)) }
    )
    var criticalProviderID: ProviderID?
    var historyPersistenceAvailable = true

    var criticalProvider: ProviderViewState? {
        if let criticalProviderID,
           let retained = providers[criticalProviderID],
           let snapshot = retained.snapshot,
           snapshot.shortWindow != nil,
           UsageAlgorithms.isFresh(snapshot) {
            return retained
        }
        return UsageAlgorithms.criticalProvider(in: Array(providers.values), now: Date())
    }
}
