import Darwin
import Dispatch
import Foundation

actor ClaudeProvider: ClaudeUsageProviding {
    nonisolated let id: ProviderID = .claude
    nonisolated let events: AsyncStream<UsageProviderEvent>

    private let continuation: AsyncStream<UsageProviderEvent>.Continuation
    private let locator: ExecutableLocator
    private let runner: any ProcessRunning
    private let usageProbe: any ClaudeUsageCommandProbing
    private let statsReader: any ClaudeStatsReading
    private let installer: ClaudeSettingsInstaller
    private let paths: AppPaths
    private var executable: URL?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var latestSnapshotAt: Date?
    private var refreshInFlight = false
    private var verifiedResetCache = ClaudeVerifiedResetCache()

    init(
        locator: ExecutableLocator = ExecutableLocator(),
        runner: any ProcessRunning = SystemProcessRunner(),
        usageProbe: any ClaudeUsageCommandProbing = ClaudeUsageCommandProbe(),
        statsReader: any ClaudeStatsReading = ClaudeStatsCacheReader(),
        installer: ClaudeSettingsInstaller = ClaudeSettingsInstaller(),
        paths: AppPaths = .live()
    ) {
        let pair = AsyncStream.makeStream(of: UsageProviderEvent.self)
        self.events = pair.stream
        self.continuation = pair.continuation
        self.locator = locator
        self.runner = runner
        self.usageProbe = usageProbe
        self.statsReader = statsReader
        self.installer = installer
        self.paths = paths
    }

    func start() async {
        continuation.yield(.connection(id, .connecting))
        let customPath = UserDefaults.standard.string(forKey: "executable.claude")
        guard let executable = locator.locate(.claude, customPath: customPath) else {
            continuation.yield(.connection(id, .unavailable))
            return
        }
        self.executable = executable
        await readVersion(executable)
        await checkAuthentication(executable)
    }

    func connect() async {
        if let executable {
            await checkAuthentication(executable)
        } else {
            await start()
        }
    }

    func refresh(reason: ProviderRefreshReason) async throws -> ProviderRefreshResult {
        _ = reason
        if installer.isInstalled() {
            _ = try? loadCapture()
        }
        guard let executable else { throw ProviderBoundaryError.executableMissing }
        guard !refreshInFlight else { throw ProviderBoundaryError.retryPaused }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let probedSnapshot = try await usageProbe.fetch(executable: executable)
        try Task.checkCancellation()
        let snapshot = verifiedResetCache.merge(probedSnapshot)
        latestSnapshotAt = max(latestSnapshotAt ?? .distantPast, snapshot.capturedAt)
        let statsRefresh: ClaudeStatsRefresh
        do {
            statsRefresh = .available(try statsReader.read(capturedAt: snapshot.capturedAt))
        } catch ClaudeStatsCacheError.unavailable {
            statsRefresh = .unavailable
        } catch let error as ClaudeStatsCacheError {
            statsRefresh = .failed(error.providerCode)
        } catch {
            statsRefresh = .failed(.unknown)
        }
        return ProviderRefreshResult(snapshot: snapshot, supplement: .claude(statsRefresh))
    }

    func installBridge() async throws {
        try installer.install()
        startDirectoryObservation()
        if latestSnapshotAt == nil { continuation.yield(.connection(id, .waiting)) }
        await readCapture()
    }

    func uninstallBridge() async throws {
        _ = try installer.uninstall()
        directorySource?.cancel()
        directorySource = nil
        if latestSnapshotAt == nil { continuation.yield(.connection(id, .waiting)) }
    }

    func isBridgeInstalled() async -> Bool {
        installer.isInstalled()
    }

    func stop() async {
        directorySource?.cancel()
        directorySource = nil
        await usageProbe.stop()
        verifiedResetCache.reset()
        latestSnapshotAt = nil
        executable = nil
        continuation.yield(.connection(id, .disconnected))
    }

    private func checkAuthentication(_ executable: URL) async {
        do {
            let result = try await runner.run(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                timeout: .seconds(10),
                outputLimit: 64 * 1_024
            )
            guard result.terminationStatus == 0,
                  let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
            else {
                continuation.yield(.connection(id, .needsLogin))
                return
            }
            let loggedIn = (object["loggedIn"] as? Bool)
                ?? (object["authenticated"] as? Bool)
                ?? false
            guard loggedIn else {
                continuation.yield(.connection(id, .needsLogin))
                return
            }
            if installer.isInstalled() {
                startDirectoryObservation()
                await readCapture()
            } else {
                continuation.yield(.connection(id, .waiting))
            }
        } catch {
            continuation.yield(.connection(id, .failed(.processFailed)))
        }
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

    private func readCapture() async {
        do {
            let snapshot = try loadCapture()
            let isNewest = snapshot.capturedAt >= (latestSnapshotAt ?? .distantPast)
            latestSnapshotAt = max(latestSnapshotAt ?? .distantPast, snapshot.capturedAt)
            continuation.yield(.snapshot(snapshot))
            if isNewest {
                continuation.yield(.connection(id, UsageAlgorithms.isFresh(snapshot) ? .connected : .stale))
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            continuation.yield(.connection(id, .waiting))
        } catch {
            continuation.yield(.connection(id, .failed(.invalidPayload)))
        }
    }

    private func loadCapture() throws -> UsageSnapshot {
        let data = try Data(contentsOf: paths.claudeCapture, options: [.mappedIfSafe])
        return verifiedResetCache.merge(try ClaudePayloadParser.parse(data))
    }

    private func startDirectoryObservation() {
        guard directorySource == nil else { return }
        do {
            try FileManager.default.createDirectory(at: paths.bridgeDirectory, withIntermediateDirectories: true)
        } catch {
            continuation.yield(.connection(id, .failed(.fileAccess)))
            return
        }

        let descriptor = open(paths.bridgeDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            continuation.yield(.connection(id, .failed(.fileAccess)))
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.readCapture()
            }
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }
}
