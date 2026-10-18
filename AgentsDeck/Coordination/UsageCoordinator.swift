import Foundation

actor UsageCoordinator {
    nonisolated let states: AsyncStream<AppViewState>

    private let stateContinuation: AsyncStream<AppViewState>.Continuation
    private let claude: any ClaudeUsageProviding
    private let codex: any CodexUsageProviding
    private let antigravity: any UsageProvider
    private let history: any HistoryStoring
    private let notifications: NotificationService
    private let diagnostics: DiagnosticsLogger
    private var state = AppViewState()
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var notificationRefreshTask: Task<Void, Never>?
    private var providerRefreshTasks: [ProviderID: Task<ProviderRefreshResult, Error>] = [:]
    private var manualRefreshID: UUID?
    private var started = false
    private var lastPruneDay: Date?
    private var lastCodexRefresh: Date?
    private var lastAntigravityRefresh: Date?
    private var refreshCadence: RefreshCadence = .oneToThreeMinutes
    private var nextScheduledRefresh: [ProviderID: Date] = [:]
    private var nextMaintenanceAt: Date?
    private var nextCodexActivityAt: Date?

    private static let codexActivityInterval: TimeInterval = 15 * 60
    private static let codexActivityFreshness: TimeInterval = 30 * 60
    private static let claudeStatsFreshness: TimeInterval = 15 * 60

    init(
        claude: any ClaudeUsageProviding = ClaudeProvider(),
        codex: any CodexUsageProviding = CodexProvider(),
        antigravity: any UsageProvider = AntigravityProvider(),
        history: any HistoryStoring = HistoryStoreFactory.makeLive(),
        notifications: NotificationService = NotificationService(),
        diagnostics: DiagnosticsLogger = DiagnosticsLogger()
    ) {
        let pair = AsyncStream.makeStream(of: AppViewState.self)
        self.states = pair.stream
        self.stateContinuation = pair.continuation
        self.claude = claude
        self.codex = codex
        self.antigravity = antigravity
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

        eventTask = Task { [claude, codex, antigravity] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in claude.events { await self.handle(event) }
                }
                group.addTask {
                    for await event in codex.events { await self.handle(event) }
                }
                group.addTask {
                    for await event in antigravity.events { await self.handle(event) }
                }
                await group.waitForAll()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.claude.start() }
            group.addTask { await self.codex.start() }
            group.addTask { await self.antigravity.start() }
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
        await antigravity.stop()
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
            if lastAntigravityRefresh.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                group.addTask {
                    await self.requestRefresh(.antigravity, reason: .popoverOpened, policy: .coalesce)
                }
            }
        }
        rescheduleAll(from: Date())
        restartPollTask()
    }

    func providerDetailOpened(_ provider: ProviderID) async {
        await requestRefresh(provider, reason: .detailOpened, policy: .coalesce)
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
        case .antigravity:
            await antigravity.stop()
            await antigravity.start()
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
        await publish()
    }

    func requestNotificationAuthorization() async -> Bool {
        await notifications.requestAuthorization()
    }

    func clearHistory() async throws {
        try await history.clearHistory()
        try await history.clearReceipts()
        state.providers[.claude]?.claudeStats = nil
        state.providers[.claude]?.claudeStatsState = .waiting
        state.providers[.codex]?.codexAccount = nil
        state.providers[.codex]?.codexActivityState = .waiting
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
        }
        await publish()
    }

    private func hydrateLatestSnapshots(now: Date = Date()) async {
        for provider in ProviderID.allCases {
            guard let snapshot = try? await history.latestSnapshot(for: provider) else { continue }
            await acceptSnapshot(snapshot, persist: false, evaluateNotifications: false, now: now)
        }
        if let account = try? await history.latestCodexAccount() {
            state.providers[.codex]?.codexAccount = account
            if let activity = account.tokenActivity {
                state.providers[.codex]?.codexActivityState = now.timeIntervalSince(activity.capturedAt)
                    <= Self.codexActivityFreshness ? .available : .stale
            }
        }
        if let stats = try? await history.latestClaudeStats() {
            state.providers[.claude]?.claudeStats = stats
            state.providers[.claude]?.claudeStatsState = now.timeIntervalSince(stats.capturedAt)
                <= Self.claudeStatsFreshness ? .available : .stale
        }
    }

    private func acceptSupplement(
        _ supplement: ProviderSupplement,
        persist: Bool,
        now: Date = Date()
    ) async {
        switch supplement {
        case let .claude(refresh):
            await acceptClaudeStats(refresh, persist: persist, now: now)
        case let .codex(refresh):
            await acceptCodexSupplement(refresh, persist: persist, now: now)
        }
    }

    private func acceptClaudeStats(
        _ refresh: ClaudeStatsRefresh,
        persist: Bool,
        now: Date
    ) async {
        let current = state.providers[.claude]?.claudeStats
        switch refresh {
        case let .available(stats):
            if current.map({ stats.capturedAt >= $0.capturedAt }) ?? true {
                state.providers[.claude]?.claudeStats = stats
                if persist { try? await history.recordClaudeStats(stats) }
            }
            if let accepted = state.providers[.claude]?.claudeStats {
                state.providers[.claude]?.claudeStatsState =
                    now.timeIntervalSince(accepted.capturedAt) <= Self.claudeStatsFreshness
                    ? .available
                    : .stale
            }
        case .unavailable:
            state.providers[.claude]?.claudeStatsState = current == nil ? .unavailable : .stale
        case let .failed(code):
            state.providers[.claude]?.claudeStatsState = current == nil ? .failed(code) : .stale
        }
        await diagnostics.log(
            .info,
            category: "provider",
            event: "claude_local_stats_updated",
            provider: .claude
        )
    }

    private func acceptCodexSupplement(
        _ refresh: CodexSupplementalRefresh,
        persist: Bool,
        now: Date
    ) async {
        var account = state.providers[.codex]?.codexAccount
            ?? .empty
        account.resetCredits = refresh.resetCredits

        switch refresh.tokenActivity {
        case .notRequested:
            break
        case let .verified(activity):
            if account.tokenActivity.map({ activity.capturedAt >= $0.capturedAt }) ?? true {
                account.tokenActivity = activity
            }
            state.providers[.codex]?.codexActivityState = .available
            nextCodexActivityAt = now.addingTimeInterval(Self.codexActivityInterval)
        case .unavailable:
            state.providers[.codex]?.codexActivityState = account.tokenActivity == nil ? .unavailable : .stale
            nextCodexActivityAt = now.addingTimeInterval(Self.codexActivityInterval)
        case let .failed(code):
            state.providers[.codex]?.codexActivityState = account.tokenActivity == nil ? .failed(code) : .stale
            nextCodexActivityAt = now.addingTimeInterval(Self.codexActivityInterval)
        }

        state.providers[.codex]?.codexAccount = account
        if persist, account.tokenActivity != nil || account.resetCredits != nil {
            try? await history.recordCodexAccount(account)
        }
        await diagnostics.log(.info, category: "provider", event: "codex_account_snapshot_updated", provider: .codex)
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
        if snapshot.provider == .antigravity { lastAntigravityRefresh = snapshot.capturedAt }
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

        if state.providers[.codex]?.codexActivityState == .available,
           let activity = state.providers[.codex]?.codexAccount?.tokenActivity,
           now.timeIntervalSince(activity.capturedAt) > Self.codexActivityFreshness {
            state.providers[.codex]?.codexActivityState = .stale
        }
        if state.providers[.claude]?.claudeStatsState == .available,
           let stats = state.providers[.claude]?.claudeStats,
           now.timeIntervalSince(stats.capturedAt) > Self.claudeStatsFreshness {
            state.providers[.claude]?.claudeStatsState = .stale
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
        state.providers[.claude]?.bridgeInstalled = isClaudeBridgeInstalled
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
            let deadlines = Array(nextScheduledRefresh.values)
                + [nextMaintenanceAt ?? now, nextCodexActivityAt ?? now]
            guard let deadline = deadlines.min() else { return }
            let milliseconds = max(1, Int(deadline.timeIntervalSince(now) * 1_000))
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }

            let wakeTime = Date()
            let dueProviders = ProviderID.allCases.filter {
                nextScheduledRefresh[$0].map { $0 <= wakeTime } ?? true
            }
            let codexActivityDue = nextCodexActivityAt.map { $0 <= wakeTime } ?? true
            for provider in dueProviders {
                scheduleNext(for: provider, from: wakeTime)
            }
            if codexActivityDue {
                nextCodexActivityAt = wakeTime.addingTimeInterval(Self.codexActivityInterval)
            }

            await withTaskGroup(of: Void.self) { group in
                for provider in dueProviders {
                    let reason: ProviderRefreshReason = provider == .codex && codexActivityDue
                        ? .scheduledActivity
                        : .scheduled
                    group.addTask {
                        await self.requestRefresh(provider, reason: reason, policy: .coalesce)
                    }
                }
                if codexActivityDue, !dueProviders.contains(.codex) {
                    group.addTask {
                        await self.requestRefresh(.codex, reason: .scheduledActivity, policy: .coalesce)
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
        if nextCodexActivityAt == nil {
            nextCodexActivityAt = now.addingTimeInterval(Self.codexActivityInterval)
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
        let task: Task<ProviderRefreshResult, Error>
        switch provider {
        case .claude:
            task = Task { [claude] in try await claude.refresh(reason: reason) }
        case .codex:
            task = Task { [codex] in try await codex.refresh(reason: reason) }
        case .antigravity:
            task = Task { [antigravity] in try await antigravity.refresh(reason: reason) }
        }
        providerRefreshTasks[provider] = task
        let result = await task.result

        guard started, state.providers[provider]?.refreshID == refreshID else { return }
        providerRefreshTasks[provider] = nil
        switch result {
        case let .success(refresh):
            await acceptSnapshot(refresh.snapshot, persist: true, evaluateNotifications: true)
            if let supplement = refresh.supplement {
                await acceptSupplement(supplement, persist: true)
            }
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
            let exitStatus: Int32? = if case let .processFailed(status) = error { status } else { nil }
            await logRefreshFailure(provider, reason: reason, code: error.code, startedAt: startedAt, exitStatus: exitStatus)
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
        if provider == .antigravity {
            if code == .authenticationRequired { return .needsLogin }
            if code == .executableMissing { return .unavailable }
        }
        if reason != .manual, let snapshot {
            return UsageAlgorithms.isFresh(snapshot, now: now) ? .connected : .stale
        }
        return .failed(code)
    }

    private func logRefreshFailure(
        _ provider: ProviderID,
        reason: ProviderRefreshReason,
        code: ProviderErrorCode,
        startedAt: Date,
        exitStatus: Int32? = nil
    ) async {
        var metadata: [String: DiagnosticValue] = [
            "duration_seconds": .double(Date().timeIntervalSince(startedAt))
        ]
        if let exitStatus { metadata["exit_status"] = .integer(Int(exitStatus)) }
        await diagnostics.log(
            .warning,
            category: "refresh",
            event: "failed_\(reason.logValue)_\(code.rawValue)",
            provider: provider,
            metadata: metadata
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
        case .scheduledActivity: "scheduled_activity"
        case .detailOpened: "detail_opened"
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
