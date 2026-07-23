import Foundation

enum ProviderRefreshReason: Equatable, Sendable {
    case startup
    case scheduled
    case scheduledActivity
    case popoverOpened
    case detailOpened
    case providerNotification
    case manual
}

struct ProviderRefreshResult: Equatable, Sendable {
    let snapshot: UsageSnapshot
    let supplement: ProviderSupplement?

    init(snapshot: UsageSnapshot, supplement: ProviderSupplement? = nil) {
        self.snapshot = snapshot
        self.supplement = supplement
    }
}

enum UsageProviderEvent: Sendable {
    case connection(ProviderID, ProviderConnectionState)
    case snapshot(UsageSnapshot)
    case version(ProviderID, String)
    case restartCount(ProviderID, Int)
    case refreshRequested(ProviderID)
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var events: AsyncStream<UsageProviderEvent> { get }

    func start() async
    func refresh(reason: ProviderRefreshReason) async throws -> ProviderRefreshResult
    func connect() async
    func stop() async
}

protocol ClaudeUsageProviding: UsageProvider {
    func installBridge() async throws
    func uninstallBridge() async throws
    func isBridgeInstalled() async -> Bool
}

protocol CodexUsageProviding: UsageProvider {
    func retry() async
}

enum ProviderBoundaryError: Error, Equatable, Sendable {
    case executableMissing
    case authenticationRequired
    case invalidPayload
    case processFailed(Int32)
    case timedOut
    case messageTooLarge
    case unsupportedProtocol
    case retryPaused

    var code: ProviderErrorCode {
        switch self {
        case .executableMissing: .executableMissing
        case .authenticationRequired: .authenticationRequired
        case .invalidPayload: .invalidPayload
        case .processFailed: .processFailed
        case .timedOut: .timedOut
        case .messageTooLarge: .invalidPayload
        case .unsupportedProtocol: .unsupportedProtocol
        case .retryPaused: .retryPaused
        }
    }
}
