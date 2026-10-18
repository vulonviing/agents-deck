import Foundation

actor AntigravityProvider: UsageProvider {
    nonisolated let id: ProviderID = .antigravity
    nonisolated let events: AsyncStream<UsageProviderEvent>

    private let continuation: AsyncStream<UsageProviderEvent>.Continuation
    private let locator: ExecutableLocator
    private let runner: any ProcessRunning
    private let customPath: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private var executable: URL?

    init(
        locator: ExecutableLocator = ExecutableLocator(),
        runner: any ProcessRunning = SystemProcessRunner(),
        customPath: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: "executable.antigravity")
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let pair = AsyncStream.makeStream(of: UsageProviderEvent.self)
        events = pair.stream
        continuation = pair.continuation
        self.locator = locator
        self.runner = runner
        self.customPath = customPath
        self.now = now
    }

    func start() async {
        continuation.yield(.connection(id, .connecting))
        guard let executable = locator.locate(.antigravity, customPath: customPath()) else {
            self.executable = nil
            continuation.yield(.connection(id, .unavailable))
            return
        }
        self.executable = executable
        if let version = try? await runner.run(
            executable: executable,
            arguments: ["--version"],
            environment: Self.commandEnvironment,
            currentDirectory: nil,
            timeout: .seconds(5),
            outputLimit: 1_024
        ), version.terminationStatus == 0 {
            let value = version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { continuation.yield(.version(id, String(value.prefix(80)))) }
        }
        continuation.yield(.connection(id, .waiting))
    }

    func refresh(reason: ProviderRefreshReason) async throws -> ProviderRefreshResult {
        _ = reason
        guard let executable else { throw ProviderBoundaryError.executableMissing }
        let result = try await runner.run(
            executable: executable,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "20s"],
            environment: Self.commandEnvironment,
            currentDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory),
            timeout: .seconds(25),
            outputLimit: 64 * 1_024
        )
        try Task.checkCancellation()
        let envelope = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        if result.terminationStatus != 0 || envelope?["status"] as? String == "ERROR" {
            let message = ((envelope?["error"] as? String) ?? String(decoding: result.stderr, as: UTF8.self))
                .lowercased()
            if message.contains("auth") || message.contains("sign in") || message.contains("login") {
                throw ProviderBoundaryError.authenticationRequired
            }
            throw ProviderBoundaryError.processFailed(result.terminationStatus)
        }
        return ProviderRefreshResult(snapshot: try AntigravityUsageParser.parse(result.stdout, capturedAt: now()))
    }

    func connect() async { await start() }

    func stop() async {
        executable = nil
        continuation.yield(.connection(id, .disconnected))
    }

    private static var commandEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": "en_US.UTF-8"
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }
}
