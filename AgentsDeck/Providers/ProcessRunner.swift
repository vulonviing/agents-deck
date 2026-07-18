import Darwin
import Foundation

struct ProcessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }
}

protocol ProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        timeout: Duration,
        outputLimit: Int
    ) async throws -> ProcessResult
}

extension ProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        outputLimit: Int
    ) async throws -> ProcessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            environment: nil,
            currentDirectory: nil,
            timeout: timeout,
            outputLimit: outputLimit
        )
    }
}

private final class LockedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var exceededLimit = false
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return }
        let remaining = max(0, limit - storage.count)
        storage.append(data.prefix(remaining))
        if data.count > remaining { exceededLimit = true }
    }

    func value() -> (data: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, exceededLimit)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var processGroup: pid_t?
    private var terminationRequested = false

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
        let shouldTerminate = terminationRequested
        lock.unlock()
        if shouldTerminate { terminate() }
    }

    func terminate() {
        lock.lock()
        terminationRequested = true
        let running = process
        let group = processGroup
        lock.unlock()
        guard let running, running.isRunning else { return }
        if let group { kill(-group, SIGTERM) }
        running.terminate()
        let pid = running.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            guard running.isRunning else { return }
            if let group { kill(-group, SIGKILL) }
            kill(pid, SIGKILL)
        }
    }
}

actor SystemProcessRunner: ProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration = .seconds(10),
        outputLimit: Int = 1_048_576
    ) async throws -> ProcessResult {
        let box = ProcessBox()

        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await Self.execute(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    currentDirectory: currentDirectory,
                    outputLimit: outputLimit,
                    processBox: box
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                box.terminate()
                throw ProviderBoundaryError.timedOut
            }

            defer {
                group.cancelAll()
                box.terminate()
            }
            guard let first = try await group.next() else {
                throw ProviderBoundaryError.processFailed(-1)
            }
            return first
        }
    }

    private nonisolated static func execute(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        outputLimit: Int,
        processBox: ProcessBox
    ) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = LockedOutputBuffer(limit: outputLimit)
        let stderrBuffer = LockedOutputBuffer(limit: outputLimit)

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        processBox.store(process)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminated in
                continuation.resume(returning: terminated.terminationStatus)
            }
            do {
                try process.run()
                processBox.registerProcessGroup()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = stdoutBuffer.value()
        let stderr = stderrBuffer.value()
        guard !stdout.exceededLimit, !stderr.exceededLimit else {
            throw ProviderBoundaryError.messageTooLarge
        }
        return ProcessResult(terminationStatus: status, stdout: stdout.data, stderr: stderr.data)
    }
}
