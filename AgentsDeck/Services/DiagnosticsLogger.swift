import Foundation
import OSLog

enum DiagnosticLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

enum DiagnosticValue: Sendable {
    case integer(Int)
    case double(Double)
    case boolean(Bool)

    fileprivate var jsonValue: Any {
        switch self {
        case let .integer(value): value
        case let .double(value): value
        case let .boolean(value): value
        }
    }
}

actor DiagnosticsLogger {
    private let paths: AppPaths
    private let fileManager: FileManager
    private let osLogger = Logger(subsystem: "com.vulonviing.agentsdeck", category: "diagnostics")
    private let encoderDateFormatter = ISO8601DateFormatter()
    private let dayFormatter: DateFormatter
    private let retention: TimeInterval = 14 * 24 * 60 * 60
    private let maximumTotalBytes: Int64 = 50 * 1_024 * 1_024
    private let maximumFileBytes: Int64 = 5 * 1_024 * 1_024

    init(paths: AppPaths = .live(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter
    }

    func log(
        _ level: DiagnosticLevel,
        category: String,
        event: String,
        provider: ProviderID? = nil,
        metadata: [String: DiagnosticValue] = [:]
    ) {
        let sanitizedCategory = Self.sanitizeIdentifier(category)
        let sanitizedEvent = Self.sanitizeIdentifier(event)
        osLogger.log(level: level.osLogType, "\(sanitizedCategory, privacy: .public).\(sanitizedEvent, privacy: .public)")

        do {
            try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
            var object: [String: Any] = [
                "timestamp": encoderDateFormatter.string(from: Date()),
                "level": level.rawValue,
                "category": sanitizedCategory,
                "event": sanitizedEvent
            ]
            if let provider { object["provider"] = provider.rawValue }
            for (key, value) in metadata {
                object[Self.sanitizeIdentifier(key)] = value.jsonValue
            }

            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let file = try writableLogURL(for: Date())
            if !fileManager.fileExists(atPath: file.path) {
                fileManager.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
            try handle.close()
        } catch {
            osLogger.error("disk_log_write_failed")
        }
    }

    func performMaintenance(now: Date = Date()) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: paths.logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-retention)
        var retained: [(url: URL, date: Date, size: Int64)] = []
        for file in files where file.pathExtension == "jsonl" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? fileManager.removeItem(at: file)
            } else {
                retained.append((file, date, Int64(values?.fileSize ?? 0)))
            }
        }

        var total = retained.reduce(Int64(0)) { $0 + $1.size }
        for file in retained.sorted(by: { $0.date < $1.date }) where total > maximumTotalBytes {
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }

    func clear() throws {
        if fileManager.fileExists(atPath: paths.logsDirectory.path) {
            try fileManager.removeItem(at: paths.logsDirectory)
        }
    }

    nonisolated var directoryURL: URL { paths.logsDirectory }

    private func writableLogURL(for date: Date) throws -> URL {
        let stem = dayFormatter.string(from: date)
        for suffix in ["", "-1", "-2"] {
            let candidate = paths.logsDirectory.appending(path: "\(stem)\(suffix).jsonl")
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if Int64(size) < maximumFileBytes { return candidate }
        }
        throw CocoaError(.fileWriteOutOfSpace)
    }

    private nonisolated static func sanitizeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(value.unicodeScalars.filter(allowed.contains).prefix(80))
    }
}

private extension DiagnosticLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}
