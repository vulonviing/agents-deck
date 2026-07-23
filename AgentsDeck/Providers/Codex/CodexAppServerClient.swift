import Foundation

enum CodexAppServerEvent: Sendable {
    case rateLimitsUpdated
    case loginCompleted
    case processExited(Int32)
    case protocolFailure
}

enum CodexClientMethod: String, CaseIterable, Sendable {
    case initialize
    case initialized
    case accountRead = "account/read"
    case accountRateLimitsRead = "account/rateLimits/read"
    case accountUsageRead = "account/usage/read"
    case accountLoginStart = "account/login/start"

    var isBackgroundSafe: Bool {
        switch self {
        case .accountRead, .accountRateLimitsRead, .accountUsageRead: true
        case .initialize, .initialized, .accountLoginStart: false
        }
    }
}

actor CodexAppServerClient {
    nonisolated let events: AsyncStream<CodexAppServerEvent>
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private let executable: URL
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var framer = JSONLFramer()
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var consecutiveMalformedLines = 0
    private var stopping = false

    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    init(executable: URL) {
        let pair = AsyncStream.makeStream(of: CodexAppServerEvent.self)
        self.events = pair.stream
        self.eventContinuation = pair.continuation
        self.executable = executable
    }

    func start() async throws {
        guard process == nil else { return }
        stopping = false

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            Task { await self.receive(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            Task { await self.didExit(terminated.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        _ = try await request(
            method: .initialize,
            params: .object([
                "clientInfo": .object([
                    "name": .string("agents_deck"),
                    "title": .string("Agents Deck"),
                    "version": .string("0.2.0")
                ])
            ])
        )
        try notify(method: .initialized, params: .object([:]))
    }

    func account() async throws -> JSONValue {
        try await request(method: .accountRead, params: .object([:]))
    }

    func rateLimits() async throws -> JSONValue {
        try await request(method: .accountRateLimitsRead)
    }

    func accountUsage() async throws -> JSONValue {
        try await request(method: .accountUsageRead)
    }

    func startChatGPTLogin() async throws -> URL {
        let result = try await request(
            method: .accountLoginStart,
            params: .object(["type": .string("chatgpt")])
        )
        guard let value = result.objectValue?["authUrl"]?.stringValue,
              let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else { throw ProviderBoundaryError.invalidPayload }
        return url
    }

    func stop() {
        stopping = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CancellationError())
        }
        pending.removeAll()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        input = nil
        process = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func request(
        method: CodexClientMethod,
        params: JSONValue? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> JSONValue {
        guard input != nil else { throw ProviderBoundaryError.processFailed(-1) }
        let id = nextID
        nextID += 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.timeoutRequest(id)
                }
                pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
                do {
                    var message: [String: JSONValue] = [
                        "id": .integer(Int64(id)),
                        "method": .string(method.rawValue),
                    ]
                    if let params { message["params"] = params }
                    try write(.object(message))
                } catch {
                    pending.removeValue(forKey: id)?.timeoutTask.cancel()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            Task { await self.cancelRequest(id) }
        }
    }

    private func notify(method: CodexClientMethod, params: JSONValue) throws {
        try write(.object(["method": .string(method.rawValue), "params": params]))
    }

    private func write(_ value: JSONValue) throws {
        guard let input else { throw ProviderBoundaryError.processFailed(-1) }
        var data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw ProviderBoundaryError.messageTooLarge }
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        do {
            for line in try framer.append(data) {
                do {
                    let message = try JSONDecoder().decode(CodexRPCResponse.self, from: line)
                    consecutiveMalformedLines = 0
                    handle(message)
                } catch {
                    consecutiveMalformedLines += 1
                    if consecutiveMalformedLines >= 3 {
                        eventContinuation.yield(.protocolFailure)
                        process?.terminate()
                    }
                }
            }
        } catch {
            eventContinuation.yield(.protocolFailure)
            process?.terminate()
        }
    }

    private func handle(_ message: CodexRPCResponse) {
        if let id = message.id, let request = pending.removeValue(forKey: id) {
            request.timeoutTask.cancel()
            if message.error != nil {
                request.continuation.resume(throwing: ProviderBoundaryError.unsupportedProtocol)
            } else if let result = message.result {
                request.continuation.resume(returning: result)
            } else {
                request.continuation.resume(throwing: ProviderBoundaryError.invalidPayload)
            }
            return
        }

        switch message.method {
        case "account/rateLimits/updated": eventContinuation.yield(.rateLimitsUpdated)
        case "account/login/completed": eventContinuation.yield(.loginCompleted)
        default: break
        }
    }

    private func timeoutRequest(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: ProviderBoundaryError.timedOut)
    }

    private func cancelRequest(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func didExit(_ status: Int32) {
        let shouldNotify = !stopping
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: ProviderBoundaryError.processFailed(status))
        }
        pending.removeAll()
        input = nil
        process = nil
        outputPipe = nil
        errorPipe = nil
        if shouldNotify { eventContinuation.yield(.processExited(status)) }
    }
}
