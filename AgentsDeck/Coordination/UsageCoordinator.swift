import Foundation

actor UsageCoordinator {
    nonisolated let states: AsyncStream<AppViewState>

    private let stateContinuation: AsyncStream<AppViewState>.Continuation
    private let claude: any ClaudeUsageProviding
    private let codex: any CodexUsageProviding
    private let history: any HistoryStoring
    private let notifications: NotificationService
    private let diagnostics: DiagnosticsLogger
    private var state = AppViewState()
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var notificationRefreshTask: Task<Void, Never>?
    private var providerRefreshTasks: [ProviderID: Task<UsageSnapshot, Error>] = [:]
    private var manualRefreshID: UUID?
    private var started = false
    private var lastPruneDay: Date?
    private var lastCodexRefresh: Date?
    private var refreshCadence: RefreshCadence = .oneToThreeMinutes
    private var nextScheduledRefresh: [ProviderID: Date] = [:]
    private var nextMaintenanceAt: Date?

    init(
        claude: any ClaudeUsageProviding = ClaudeProvider(),
        codex: any CodexUsageProviding = CodexProvider(),
        history: any HistoryStoring = HistoryStoreFactory.makeLive(),
        notifications: NotificationService = NotificationService(),
        diagnostics: DiagnosticsLogger = DiagnosticsLogger()
    ) {
        let pair = AsyncStream.makeStream(of: AppViewState.self)
        self.states = pair.stream
        self.stateContinuation = pair.continuation
        self.claude = claude
        self.codex = codex
        self.history = history
        self.notifications = notifications
        self.diagnostics = diagnostics
    }

    func start(refreshCadence: RefreshCadence = .oneToThreeMinutes) async {
        guard !started else { return }
        started = true
        self.refreshCadence = refreshCadence
        state.historyPersistenceAvailable = history.isPersistent
        await diagnostics.log(.info, category: "app", event: "coordinator_started")
        if !history.isPersistent {
            await diagnostics.log(.warning, category: "persistence", event: "history_store_unavailable")
        }

        await hydrateLatestSnapshots()
        await publish()

        eventTask = Task { [claude, codex] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in claude.events { await self.handle(event) }
                }
                group.addTask {
                    for await event in codex.events { await self.handle(event) }
                }
                await group.waitForAll()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.claude.start() }
            group.addTask { await self.codex.start() }
        }
        await maintenance()
        await withTaskGroup(of: Void.self) { group in
            for provider in ProviderID.allCases {
                group.addTask {
                    await self.requestRefresh(provider, reason: .startup, policy: .coalesce)
                }
            }
        }
        rescheduleAll(from: Date())
        restartPollTask()
    }

    func stop() async {
        started = false
        pollTask?.cancel()
        notificationRefreshTask?.cancel()
        pollTask = nil
        notificationRefreshTask = nil
        manualRefreshID = nil
        let refreshTasks = Array(providerRefreshTasks.values)
        providerRefreshTasks.removeAll()
        for task in refreshTasks { task.cancel() }
        for task in refreshTasks { _ = await task.result }
        for provider in ProviderID.allCases { state.providers[provider]?.refreshID = nil }
        eventTask?.cancel()
        eventTask = nil
        await claude.stop()
        await codex.stop()
        await diagnostics.log(.info, category: "app", event: "coordinator_stopped")
    }

    func popoverOpened() async {
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.requestRefresh(.claude, reason: .popoverOpened, policy: .coalesce)
            }
            if lastCodexRefresh.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                group.addTask {
                    await self.requestRefresh(.codex, reason: .popoverOpened, policy: .coalesce)
                }
            }
        }
        rescheduleAll(from: Date())
        restartPollTask()
    }

    func manualRefresh() async {
        let requestID = UUID()
        manualRefreshID = requestID
        await withTaskGroup(of: Void.self) { group in
            for provider in ProviderID.allCases {
                group.addTask {
                    await self.requestRefresh(provider, reason: .manual, policy: .replace)
                }
            }
        }
        guard manualRefreshID == requestID else { return }
        rescheduleAll(from: Date())
        restartPollTask()
        await maintenance()
    }

    func setRefreshCadence(_ cadence: RefreshCadence) {
        guard refreshCadence != cadence else { return }
        refreshCadence = cadence
        rescheduleAll(from: Date())
        restartPollTask()
    }

    func connectClaude() async { await claude.connect() }
    func connectCodex() async { await codex.connect() }
    func retryCodex() async { await codex.retry() }

    func restart(_ provider: ProviderID) async {
        switch provider {
        case .claude:
            await claude.stop()
            await claude.start()
        case .codex:
            await codex.stop()
            await codex.start()
        }
    }

    func installClaudeBridge() async throws {
        try await claude.installBridge()
        state.providers[.claude]?.bridgeInstalled = true
        await publish()
    }

    func uninstallClaudeBridge() async throws {
        try await claude.uninstallBridge()
        state.providers[.claude]?.bridgeInstalled = false
        state.providers[.claude]?.sessionDetailsEnabled = false
        state.providers[.claude]?.latestSessionConfiguration = nil
        try await history.clearSessionConfigurations()
        await publish()
    }

    func enableClaudeSessionDetails() async throws {
        try await claude.enableSessionDetails()
        state.providers[.claude]?.sessionDetailsEnabled = true
        await publish()
    }

    func disableClaudeSessionDetails() async throws {
        try await claude.disableSessionDetails()
        try await history.clearSessionConfigurations()
        state.providers[.claude]?.sessionDetailsEnabled = false
        state.providers[.claude]?.latestSessionConfiguration = nil
        await publish()
    }

    func clearSessionDetails() async throws {
        try await history.clearSessionConfigurations()
        state.providers[.claude]?.latestSessionConfiguration = nil
        await publish()
    }

    func sessionConfigurations(for provider: ProviderID, since: Date) async -> [SessionConfigurationPeriod] {
        (try? await history.sessionConfigurations(for: provider, since: since)) ?? []
    }

    func requestNotificationAuthorization() async -> Bool {
        await notifications.requestAuthorization()
    }

    func clearHistory() async throws {
        try await history.clearHistory()
        try await history.clearReceipts()
        await publish()
    }

    func clearLogs() async throws {
        try await diagnostics.clear()
    }

    nonisolated var logsDirectory: URL { diagnostics.directoryURL }

    private func handle(_ event: UsageProviderEvent) async {
        switch event {
        case let .connection(provider, connection):
            let resolved = resolvedConnection(connection, for: provider)
            state.providers[provider]?.connection = resolved
            await diagnostics.log(
                connection == .connected ? .info : .warning,
                category: "provider",
                event: "state_\(connection.logValue)",
                provider: provider
            )
        case let .snapshot(snapshot):
            await acceptSnapshot(snapshot, persist: true, evaluateNotifications: true)
        case let .version(provider, version):
            state.providers[provider]?.executableVersion = version
            await diagnostics.log(.info, category: "provider", event: "version_detected", provider: provider)
        case let .restartCount(provider, count):
            state.providers[provider]?.restartCount = count
        case let .refreshRequested(provider):
            guard provider == .codex else { break }
            notificationRefreshTask?.cancel()
            notificationRefreshTask = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self.requestRefresh(.codex, reason: .providerNotification, policy: .coalesce)
                self.scheduleNext(for: .codex, from: Date())
                self.restartPollTask()
            }
        case let .sessionConfiguration(snapshot):
            if state.providers[snapshot.provider]?.latestSessionConfiguration.map({
                snapshot.capturedAt >= $0.capturedAt
            }) ?? true {
                state.providers[snapshot.provider]?.latestSessionConfiguration = snapshot
            }
            try? await history.recordSessionConfiguration(snapshot)
            await diagnostics.log(.info, category: "provider", event: "session_metadata_verified", provider: snapshot.provider)
        }
        await publish()
    }

    private func hydrateLatestSnapshots(now: Date = Date()) async {
        for provider in ProviderID.allCases {
            guard let snapshot = try? await history.latestSnapshot(for: provider) else { continue }
            await acceptSnapshot(snapshot, persist: false, evaluateNotifications: false, now: now)
        }
        if let latest = try? await history.sessionConfigurations(
            for: .claude,
            since: now.addingTimeInterval(-365 * 24 * 60 * 60)
        ).first {
            state.providers[.claude]?.latestSessionConfiguration = SessionConfigurationSnapshot(
                provider: latest.provider, capturedAt: latest.lastSeenAt, source: latest.source,
                modelID: latest.modelID, modelDisplayName: latest.modelDisplayName,
                effort: latest.effort, thinkingEnabled: latest.thinkingEnabled, agentName: latest.agentName
            )
        }
    }

    private func acceptSnapshot(
        _ snapshot: UsageSnapshot,
        persist: Bool,
        evaluateNotifications: Bool,
        now: Date = Date()
    ) async {
        // The command probe intentionally has no billing field. Preserve the
        // independently verified status-line value when its windows arrive.
        if snapshot.source != .claudeUsageCommand {
            state.providers[snapshot.provider]?.billing = snapshot.billing
            state.providers[snapshot.provider]?.billingCapturedAt = snapshot.billing == nil
                ? nil
                : snapshot.capturedAt
        }

        let current = state.providers[snapshot.provider]?.snapshot
        guard current.map({ snapshot.capturedAt >= $0.capturedAt }) ?? true else {
            await diagnostics.log(
                .debug,
                category: "provider",
                event: "snapshot_ignored_older",
                provider: snapshot.provider
            )
            return
        }

        state.providers[snapshot.provider]?.snapshot = snapshot
        state.providers[snapshot.provider]?.connection = UsageAlgorithms.isFresh(snapshot, now: now)
            ? .connected
            : .stale
        if snapshot.provider == .codex { lastCodexRefresh = snapshot.capturedAt }
        if persist { try? await history.record(snapshot) }
        if evaluateNotifications { await notifications.evaluate(snapshot, receipts: history) }
        await diagnostics.log(.info, category: "provider", event: "snapshot_verified", provider: snapshot.provider)
    }

    private func resolvedConnection(
        _ connection: ProviderConnectionState,
        for provider: ProviderID,
        now: Date = Date()
    ) -> ProviderConnectionState {
        guard connection == .connected || connection == .stale,
              let snapshot = state.providers[provider]?.snapshot
        else { return connection }
        return UsageAlgorithms.isFresh(snapshot, now: now) ? .connected : .stale
    }

    private func maintenance(now: Date = Date()) async {
        for provider in ProviderID.allCases {
            guard let snapshot = state.providers[provider]?.snapshot,
                  !UsageAlgorithms.isFresh(snapshot, now: now),
                  state.providers[provider]?.connection == .connected
            else { continue }
            state.providers[provider]?.connection = .stale
        }

        if lastPruneDay.map({ !Calendar.current.isDate($0, inSameDayAs: now) }) ?? true {
            try? await history.prune(before: now.addingTimeInterval(-365 * 24 * 60 * 60))
            await diagnostics.performMaintenance(now: now)
            lastPruneDay = now
        }
        await publish()
    }

    private func publish() async {
        let isClaudeBridgeInstalled = await claude.isBridgeInstalled()
        let sessionDetailsEnabled = await claude.isSessionDetailsEnabled()
        state.providers[.claude]?.bridgeInstalled = isClaudeBridgeInstalled
        state.providers[.claude]?.sessionDetailsEnabled = sessionDetailsEnabled
        state.criticalProviderID = UsageAlgorithms.criticalProvider(
            in: Array(state.providers.values),
            keeping: state.criticalProviderID
        )?.provider
        stateContinuation.yield(state)
    }

    private func restartPollTask() {
        pollTask?.cancel()
        guard started else { return }
        pollTask = Task { await self.runPollLoop() }
    }

    private func runPollLoop() async {
        while !Task.isCancelled {
            let now = Date()
            let deadlines = Array(nextScheduledRefresh.values) + [nextMaintenanceAt ?? now]
            guard let deadline = deadlines.min() else { return }
            let milliseconds = max(1, Int(deadline.timeIntervalSince(now) * 1_000))
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }

            let wakeTime = Date()
            let dueProviders = ProviderID.allCases.filter {
                nextScheduledRefresh[$0].map { $0 <= wakeTime } ?? true
            }
            for provider in dueProviders {
                scheduleNext(for: provider, from: wakeTime)
            }

            await withTaskGroup(of: Void.self) { group in
                for provider in dueProviders {
                    group.addTask {
                        await self.requestRefresh(provider, reason: .scheduled, policy: .coalesce)
                    }
                }
            }

            if nextMaintenanceAt.map({ $0 <= wakeTime }) ?? true {
                nextMaintenanceAt = wakeTime.addingTimeInterval(60)
                await maintenance(now: wakeTime)
            }
        }
    }

    private func rescheduleAll(from now: Date) {
        for provider in ProviderID.allCases {
            scheduleNext(for: provider, from: now)
        }
        nextMaintenanceAt = now.addingTimeInterval(60)
    }

    private func scheduleNext(for provider: ProviderID, from now: Date) {
        var generator = SystemRandomNumberGenerator()
        let delay = refreshCadence.nextDelaySeconds(using: &generator)
        nextScheduledRefresh[provider] = now.addingTimeInterval(TimeInterval(delay))
    }

    private func requestRefresh(
        _ provider: ProviderID,
        reason: ProviderRefreshReason,
        policy: RefreshRequestPolicy
    ) async {
        guard started else { return }

        if let current = providerRefreshTasks[provider] {
            guard policy == .replace else { return }
            let replacementID = UUID()
            state.providers[provider]?.refreshID = replacementID
            await publish()
            current.cancel()
            _ = await current.result
            guard started, state.providers[provider]?.refreshID == replacementID else { return }
            await beginRefresh(provider, reason: reason, refreshID: replacementID)
            return
        }

        let refreshID = UUID()
        state.providers[provider]?.refreshID = refreshID
        await publish()
        await beginRefresh(provider, reason: reason, refreshID: refreshID)
    }

    private func beginRefresh(
        _ provider: ProviderID,
        reason: ProviderRefreshReason,
        refreshID: UUID
    ) async {
        let startedAt = Date()
        await diagnostics.log(
            .info,
            category: "refresh",
            event: "started_\(reason.logValue)",
            provider: provider
        )
        let task: Task<UsageSnapshot, Error>
        switch provider {
        case .claude:
            task = Task { [claude] in try await claude.refresh(reason: reason) }
        case .codex:
            task = Task { [codex] in try await codex.refresh(reason: reason) }
        }
        providerRefreshTasks[provider] = task
        let result = await task.result

        guard started, state.providers[provider]?.refreshID == refreshID else { return }
        providerRefreshTasks[provider] = nil
        switch result {
        case let .success(snapshot):
            await acceptSnapshot(snapshot, persist: true, evaluateNotifications: true)
            await diagnostics.log(
                .info,
                category: "refresh",
                event: "succeeded_\(reason.logValue)",
                provider: provider,
                metadata: ["duration_seconds": .double(Date().timeIntervalSince(startedAt))]
            )
        case let .failure(error as ProviderBoundaryError):
            let connection = refreshFailureState(
                provider: provider,
                code: error.code,
                reason: reason
            )
            state.providers[provider]?.connection = connection
            await logRefreshFailure(provider, reason: reason, code: error.code, startedAt: startedAt)
        case .failure(is CancellationError):
            await diagnostics.log(
                .info,
                category: "refresh",
                event: "cancelled_\(reason.logValue)",
                provider: provider,
                metadata: ["duration_seconds": .double(Date().timeIntervalSince(startedAt))]
            )
        case .failure:
            let connection = refreshFailureState(
                provider: provider,
                code: .processFailed,
                reason: reason
            )
            state.providers[provider]?.connection = connection
            await logRefreshFailure(provider, reason: reason, code: .processFailed, startedAt: startedAt)
        }
        state.providers[provider]?.refreshID = nil
        await publish()
    }

    private func refreshFailureState(
        provider: ProviderID,
        code: ProviderErrorCode,
        reason: ProviderRefreshReason,
        now: Date = Date()
    ) -> ProviderConnectionState {
        let snapshot = state.providers[provider]?.snapshot
        if reason != .manual, let snapshot {
            return UsageAlgorithms.isFresh(snapshot, now: now) ? .connected : .stale
        }
        return .failed(code)
    }

    private func logRefreshFailure(
        _ provider: ProviderID,
        reason: ProviderRefreshReason,
        code: ProviderErrorCode,
        startedAt: Date
    ) async {
        await diagnostics.log(
            .warning,
            category: "refresh",
            event: "failed_\(reason.logValue)_\(code.rawValue)",
            provider: provider,
            metadata: ["duration_seconds": .double(Date().timeIntervalSince(startedAt))]
        )
    }
}

private enum RefreshRequestPolicy {
    case coalesce
    case replace
}

private extension ProviderRefreshReason {
    var logValue: String {
        switch self {
        case .startup: "startup"
        case .scheduled: "scheduled"
        case .popoverOpened: "popover_opened"
        case .providerNotification: "provider_notification"
        case .manual: "manual"
        }
    }
}

private extension ProviderConnectionState {
    var logValue: String {
        switch self {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .needsLogin: "needs_login"
        case .needsConsent: "needs_consent"
        case .waiting: "waiting"
        case .connected: "connected"
        case .stale: "stale"
        case .unavailable: "unavailable"
        case let .failed(code): "failed_\(code.rawValue)"
        }
    }
}
