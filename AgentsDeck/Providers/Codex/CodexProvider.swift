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

    func refresh(reason: ProviderRefreshReason) async throws -> UsageSnapshot {
        guard !refreshInFlight else { throw ProviderBoundaryError.retryPaused }
        if client == nil, reason == .manual {
            await start()
        }
        guard let client else {
            throw ProviderBoundaryError.processFailed(-1)
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        return try await refresh(using: client)
    }

    func stop() async {
        stopped = true
        restartTask?.cancel()
        clientEventTask?.cancel()
        await client?.stop()
        client = nil
        continuation.yield(.connection(id, .disconnected))
    }

    func retry() async {
        failures.removeAll()
        await stop()
        stopped = false
        await start()
    }

    private func refresh(using client: CodexAppServerClient) async throws -> UsageSnapshot {
        let response = try await client.rateLimits()
        try Task.checkCancellation()
        let snapshot = try CodexRateLimitParser.parse(response)
        connectedSince = connectedSince ?? Date()
        if let connectedSince, Date().timeIntervalSince(connectedSince) >= 5 * 60 {
            failures.removeAll()
        }
        return snapshot
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
