import Darwin
import Foundation

protocol ClaudeUsageCommandProbing: Sendable {
    func fetch(executable: URL) async throws -> UsageSnapshot
    func stop() async
}

actor ClaudeUsageCommandProbe: ClaudeUsageCommandProbing {
    private static let outputLimit = 262_144

    private let runner: any ProcessRunning
    private let paths: AppPaths
    private let homeDirectory: URL
    private let fileManager: FileManager
    private var activePTYProcess: ClaudeProbeProcessController?

    init(
        runner: any ProcessRunning = SystemProcessRunner(),
        paths: AppPaths = .live(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.paths = paths
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func fetch(executable: URL) async throws -> UsageSnapshot {
        try prepareWorkingDirectory()
        do {
            return try await directFetch(executable: executable)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await ptyFetch(executable: executable)
        }
    }

    func stop() async {
        activePTYProcess?.terminate()
        activePTYProcess = nil
    }

    private func directFetch(executable: URL) async throws -> UsageSnapshot {
        let sessionID = UUID()
        defer { cleanupProbeArtifact(sessionID: sessionID) }
        let result = try await runner.run(
            executable: executable,
            arguments: launchArguments(sessionID: sessionID, command: "/usage"),
            environment: launchEnvironment(),
            currentDirectory: paths.claudeProbeDirectory,
            timeout: .seconds(8),
            outputLimit: Self.outputLimit
        )
        guard result.terminationStatus == 0 else {
            throw ProviderBoundaryError.processFailed(result.terminationStatus)
        }
        return try ClaudeUsageCommandParser.parse(combinedOutput(result))
    }

    private func ptyFetch(executable: URL) async throws -> UsageSnapshot {
        let sessionID = UUID()
        defer { cleanupProbeArtifact(sessionID: sessionID) }
        let controller = ClaudeProbeProcessController()
        activePTYProcess = controller
        defer { activePTYProcess = nil }

        let data = try await Self.captureUsingSystemPTY(
            executable: executable,
            arguments: launchArguments(sessionID: sessionID, command: nil),
            environment: launchEnvironment(),
            currentDirectory: paths.claudeProbeDirectory,
            controller: controller,
            outputLimit: Self.outputLimit
        )
        return try ClaudeUsageCommandParser.parse(data)
    }

    private func launchArguments(sessionID: UUID, command: String?) -> [String] {
        var arguments = [
            "--safe-mode",
            "--allowed-tools", "",
            "--session-id", sessionID.uuidString.lowercased(),
        ]
        if let command { arguments.append(command) }
        return arguments
    }

    private func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR")
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["PWD"] = paths.claudeProbeDirectory.path
        return environment
    }

    private func prepareWorkingDirectory() throws {
        try fileManager.createDirectory(
            at: paths.claudeProbeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.claudeProbeDirectory.path
        )
    }

    private func cleanupProbeArtifact(sessionID: UUID) {
        let encodedDirectory = paths.claudeProbeDirectory.path.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                Character(scalar)
            default:
                "-"
            }
        }
        let projectDirectory = homeDirectory
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
            .appending(path: String(encodedDirectory), directoryHint: .isDirectory)
        let artifact = projectDirectory.appending(path: "\(sessionID.uuidString.lowercased()).jsonl")
        guard let values = try? artifact.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return }
        try? fileManager.removeItem(at: artifact)
        if (try? fileManager.contentsOfDirectory(atPath: projectDirectory.path).isEmpty) == true {
            try? fileManager.removeItem(at: projectDirectory)
        }
    }

    private func combinedOutput(_ result: ProcessResult) -> Data {
        var output = result.stdout
        if !result.stderr.isEmpty {
            output.append(Data("\n".utf8))
            output.append(result.stderr)
        }
        return output
    }

    private nonisolated static func captureUsingSystemPTY(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        controller: ClaudeProbeProcessController,
        outputLimit: Int
    ) async throws -> Data {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = ClaudeProbeOutputBuffer(limit: outputLimit)
        let input = ClaudeProbeInput(handle: inputPipe.fileHandleForWriting)

        process.executableURL = URL(filePath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", executable.path] + arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        controller.store(process)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { _ in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    output.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                    output.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
                    input.close()
                    let value = output.value()
                    if value.exceededLimit {
                        continuation.resume(throwing: ProviderBoundaryError.messageTooLarge)
                    } else {
                        continuation.resume(returning: value.data)
                    }
                }
                do {
                    try process.run()
                    controller.registerProcessGroup()
                    Task {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            input.write("/usage\r")
                            try await Task.sleep(for: .seconds(6))
                            input.write("\u{1B}/exit\r")
                            try await Task.sleep(for: .milliseconds(400))
                        } catch {}
                        controller.terminate()
                    }
                } catch {
                    input.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            input.close()
            controller.terminate()
        }
    }
}

private final class ClaudeProbeOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var exceededLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !value.isEmpty else { return }
        let remaining = max(0, limit - data.count)
        data.append(value.prefix(remaining))
        if value.count > remaining { exceededLimit = true }
    }

    func value() -> (data: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, exceededLimit)
    }
}

private final class ClaudeProbeInput: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ string: String) {
        lock.lock()
        let current = handle
        lock.unlock()
        try? current?.write(contentsOf: Data(string.utf8))
    }

    func close() {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        try? current?.close()
    }
}

private final class ClaudeProbeProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var processGroup: pid_t?

    func store(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func registerProcessGroup() {
        lock.lock()
        guard let process else {
            lock.unlock()
            return
        }
        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 { processGroup = pid }
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let current = process
        let group = processGroup
        lock.unlock()
        guard let current, current.isRunning else { return }
        if let group { kill(-group, SIGTERM) }
        current.terminate()
        let pid = current.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if current.isRunning {
                if let group { kill(-group, SIGKILL) }
                kill(pid, SIGKILL)
            }
        }
    }
}
