import AppKit
import Foundation

actor CodexProvider: CodexUsageProviding {
    nonisolated let id: ProviderID = .codex
    nonisolated let events: AsyncStream<UsageProviderEvent>

    private let continuation: AsyncStream<UsageProviderEvent>.Continuation
    private let locator: ExecutableLocator
    private let runner: any ProcessRunning
    private var executable: URL?
    private var client: CodexAppServerClient?
    private var clientEventTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var failures: [Date] = []
    private var connectedSince: Date?
    private var stopped = false
    private var refreshInFlight = false
    private var lastActivityAttemptAt: Date?

    init(
        locator: ExecutableLocator = ExecutableLocator(),
        runner: any ProcessRunning = SystemProcessRunner()
    ) {
        let pair = AsyncStream.makeStream(of: UsageProviderEvent.self)
        self.events = pair.stream
        self.continuation = pair.continuation
        self.locator = locator
        self.runner = runner
    }

    func start() async {
        stopped = false
        continuation.yield(.connection(id, .connecting))
        let customPath = UserDefaults.standard.string(forKey: "executable.codex")
        guard let executable = locator.locate(.codex, customPath: customPath) else {
            continuation.yield(.connection(id, .unavailable))
            return
        }
        self.executable = executable
        await readVersion(executable)
        await launchClient(executable)
    }

    func connect() async {
        if client == nil { await start() }
        guard let client else { return }
        continuation.yield(.connection(id, .connecting))
        do {
            let url = try await client.startChatGPTLogin()
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        } catch {
            continuation.yield(.connection(id, .failed(.processFailed)))
        }
    }

    func refresh(reason: ProviderRefreshReason) async throws -> ProviderRefreshResult {
        guard !refreshInFlight else { throw ProviderBoundaryError.retryPaused }
        if client == nil, reason == .manual {
            await start()
        }
        guard let client else {
            throw ProviderBoundaryError.processFailed(-1)
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        return try await refresh(using: client, reason: reason)
    }

    func stop() async {
        stopped = true
        restartTask?.cancel()
        clientEventTask?.cancel()
        await client?.stop()
        client = nil
        lastActivityAttemptAt = nil
        continuation.yield(.connection(id, .disconnected))
    }

    func retry() async {
        failures.removeAll()
        await stop()
        stopped = false
        await start()
    }

    private func refresh(
        using client: CodexAppServerClient,
        reason: ProviderRefreshReason
    ) async throws -> ProviderRefreshResult {
        let now = Date()
        let shouldFetchActivity = shouldFetchActivity(for: reason, now: now)
        let activityTask: Task<JSONValue, Error>? = if shouldFetchActivity {
            Task { try await client.accountUsage() }
        } else {
            nil
        }
        if shouldFetchActivity { lastActivityAttemptAt = now }

        defer { activityTask?.cancel() }
        let response = try await client.rateLimits()
        try Task.checkCancellation()
        let parsed = try CodexRateLimitParser.parseRefresh(response, now: now)
        let tokenActivity = await tokenActivityResult(from: activityTask, now: now)
        connectedSince = connectedSince ?? Date()
        if let connectedSince, Date().timeIntervalSince(connectedSince) >= 5 * 60 {
            failures.removeAll()
        }
        return ProviderRefreshResult(
            snapshot: parsed.snapshot,
            supplement: .codex(CodexSupplementalRefresh(
                resetCredits: parsed.resetCredits,
                tokenActivity: tokenActivity
            ))
        )
    }

    private func shouldFetchActivity(for reason: ProviderRefreshReason, now: Date) -> Bool {
        let age = lastActivityAttemptAt.map { now.timeIntervalSince($0) }
        switch reason {
        case .startup, .manual, .scheduledActivity:
            return true
        case .popoverOpened, .detailOpened:
            return age.map { $0 >= 60 } ?? true
        case .scheduled, .providerNotification:
            return false
        }
    }

    private func tokenActivityResult(
        from task: Task<JSONValue, Error>?,
        now: Date
    ) async -> CodexTokenActivityRefresh {
        guard let task else { return .notRequested }
        switch await task.result {
        case let .success(response):
            do { return .verified(try CodexTokenActivityParser.parse(response, now: now)) }
            catch let error as ProviderBoundaryError { return .failed(error.code) }
            catch { return .failed(.invalidPayload) }
        case .failure(is CancellationError):
            return .failed(.unknown)
        case let .failure(error as ProviderBoundaryError):
            if error == .unsupportedProtocol || error == .authenticationRequired {
                return .unavailable
            }
            return .failed(error.code)
        case .failure:
            return .failed(.processFailed)
        }
    }

    private func launchClient(_ executable: URL) async {
        let client = CodexAppServerClient(executable: executable)
        self.client = client
        clientEventTask?.cancel()
        clientEventTask = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        do {
            try await client.start()
            let account = try await client.account()
            let accountObject = account.objectValue
            if accountObject?["account"] == nil || accountObject?["account"] == .null {
                continuation.yield(.connection(id, .needsLogin))
            } else {
                connectedSince = Date()
                continuation.yield(.connection(id, .connected))
                continuation.yield(.refreshRequested(id))
            }
        } catch {
            continuation.yield(.connection(id, .failed(.unsupportedProtocol)))
            await scheduleRestart()
        }
    }

    private func handle(_ event: CodexAppServerEvent) async {
        switch event {
        case .rateLimitsUpdated:
            continuation.yield(.refreshRequested(id))
        case .loginCompleted:
            guard let client else { return }
            if let account = try? await client.account(),
               account.objectValue?["account"] != nil,
               account.objectValue?["account"] != .null {
                continuation.yield(.connection(id, .connected))
                continuation.yield(.refreshRequested(id))
            }
        case .processExited, .protocolFailure:
            await scheduleRestart()
        }
    }

    private func scheduleRestart() async {
        guard !stopped, restartTask == nil else { return }
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 10 * 60 }
        guard failures.count < 5 else {
            continuation.yield(.connection(id, .failed(.retryPaused)))
            return
        }
        failures.append(now)
        let delays = [1, 2, 4, 8, 16]
        let delay = delays[min(failures.count - 1, delays.count - 1)]
        continuation.yield(.restartCount(id, failures.count))
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            await self.performRestart()
        }
    }

    private func performRestart() async {
        restartTask = nil
        await client?.stop()
        client = nil
        connectedSince = nil
        guard let executable, !stopped else { return }
        await launchClient(executable)
    }

    private func readVersion(_ executable: URL) async {
        guard let result = try? await runner.run(
            executable: executable,
            arguments: ["--version"],
            timeout: .seconds(5),
            outputLimit: 8 * 1_024
        ), result.terminationStatus == 0 else { return }
        let version = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { continuation.yield(.version(id, version)) }
    }
}
