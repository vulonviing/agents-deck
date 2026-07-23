import Foundation
import CoreData
import SwiftData

@Model
final class UsageRecord {
    @Attribute(.unique) var minuteKey: String
    var providerRaw: String
    var capturedAt: Date
    var sourceRaw: String
    var fiveHourPercent: Double?
    var fiveHourReset: Date?
    var sevenDayPercent: Double?
    var sevenDayReset: Date?
    var fiveHourDurationMinutes: Int?
    var sevenDayDurationMinutes: Int?
    var billingKindRaw: String?
    var billingValue: String?
    var billingCurrency: String?
    var billingLimitValue: String?
    var billingRemainingPercent: Int?
    var billingReset: Date?

    init(snapshot: UsageSnapshot, minuteKey: String) {
        self.minuteKey = minuteKey
        self.providerRaw = snapshot.provider.rawValue
        self.capturedAt = snapshot.capturedAt
        self.sourceRaw = snapshot.source.rawValue
        self.fiveHourPercent = snapshot[.fiveHour]?.usedPercent
        self.fiveHourReset = snapshot[.fiveHour]?.resetsAt
        self.sevenDayPercent = snapshot[.sevenDay]?.usedPercent
        self.sevenDayReset = snapshot[.sevenDay]?.resetsAt
        self.fiveHourDurationMinutes = snapshot[.fiveHour]?.durationMinutes
        self.sevenDayDurationMinutes = snapshot[.sevenDay]?.durationMinutes
        self.billingKindRaw = snapshot.billing?.kind.rawValue
        self.billingValue = snapshot.billing?.providerDisplayValue
            ?? snapshot.billing?.decimalValue.map { NSDecimalNumber(decimal: $0).stringValue }
        self.billingCurrency = snapshot.billing?.currencyCode
        self.billingLimitValue = snapshot.billing?.limitDisplayValue
        self.billingRemainingPercent = snapshot.billing?.remainingPercent
        self.billingReset = snapshot.billing?.resetsAt
    }

    func update(with snapshot: UsageSnapshot) {
        capturedAt = snapshot.capturedAt
        sourceRaw = snapshot.source.rawValue
        fiveHourPercent = snapshot[.fiveHour]?.usedPercent
        fiveHourReset = snapshot[.fiveHour]?.resetsAt
        sevenDayPercent = snapshot[.sevenDay]?.usedPercent
        sevenDayReset = snapshot[.sevenDay]?.resetsAt
        fiveHourDurationMinutes = snapshot[.fiveHour]?.durationMinutes
        sevenDayDurationMinutes = snapshot[.sevenDay]?.durationMinutes
        billingKindRaw = snapshot.billing?.kind.rawValue
        billingValue = snapshot.billing?.providerDisplayValue
            ?? snapshot.billing?.decimalValue.map { NSDecimalNumber(decimal: $0).stringValue }
        billingCurrency = snapshot.billing?.currencyCode
        billingLimitValue = snapshot.billing?.limitDisplayValue
        billingRemainingPercent = snapshot.billing?.remainingPercent
        billingReset = snapshot.billing?.resetsAt
    }

    func snapshot() -> UsageSnapshot? {
        guard let provider = ProviderID(rawValue: providerRaw),
              let source = UsageSource(rawValue: sourceRaw)
        else { return nil }
        var windows: [UsageWindowKind: UsageWindow] = [:]
        if let fiveHourPercent {
            windows[.fiveHour] = UsageWindow(
                kind: .fiveHour,
                usedPercent: fiveHourPercent,
                resetsAt: fiveHourReset,
                durationMinutes: fiveHourDurationMinutes
            )
        }
        if let sevenDayPercent {
            windows[.sevenDay] = UsageWindow(
                kind: .sevenDay,
                usedPercent: sevenDayPercent,
                resetsAt: sevenDayReset,
                durationMinutes: sevenDayDurationMinutes
            )
        }
        let billing: ProviderBillingValue?
        switch billingKindRaw.flatMap(BillingKind.init(rawValue:)) {
        case .sessionCost:
            billing = billingValue.flatMap { Decimal(string: $0) }.map {
                .sessionCost($0, currencyCode: billingCurrency ?? "USD")
            }
        case .creditBalance:
            billing = billingValue.map(ProviderBillingValue.creditBalance)
        case .unlimitedCredits:
            billing = .unlimitedCredits
        case .monthlyCreditUsage:
            if let used = billingValue,
               let limit = billingLimitValue,
               let remainingPercent = billingRemainingPercent {
                billing = .monthlyCreditUsage(
                    used: used,
                    limit: limit,
                    remainingPercent: remainingPercent,
                    resetsAt: billingReset
                )
            } else {
                billing = nil
            }
        case nil:
            billing = nil
        }
        return UsageSnapshot(provider: provider, capturedAt: capturedAt, source: source, windows: windows, billing: billing)
    }
}

@Model
final class LatestUsageRecord {
    @Attribute(.unique) var providerRaw: String
    var capturedAt: Date
    var payload: Data

    init(snapshot: UsageSnapshot) throws {
        providerRaw = snapshot.provider.rawValue
        capturedAt = snapshot.capturedAt
        payload = try JSONEncoder().encode(snapshot)
    }

    func update(with snapshot: UsageSnapshot) throws {
        providerRaw = snapshot.provider.rawValue
        capturedAt = snapshot.capturedAt
        payload = try JSONEncoder().encode(snapshot)
    }

    func snapshot() -> UsageSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: payload),
              snapshot.provider.rawValue == providerRaw,
              snapshot.capturedAt == capturedAt
        else { return nil }
        return snapshot
    }
}

@Model
final class LatestCodexAccountRecord {
    @Attribute(.unique) var key: String
    var capturedAt: Date
    var payload: Data

    init(snapshot: CodexAccountSnapshot) throws {
        key = ProviderID.codex.rawValue
        capturedAt = Self.latestCapture(in: snapshot)
        payload = try JSONEncoder().encode(snapshot)
    }

    func update(with snapshot: CodexAccountSnapshot) throws {
        capturedAt = Self.latestCapture(in: snapshot)
        payload = try JSONEncoder().encode(snapshot)
    }

    func snapshot() -> CodexAccountSnapshot? {
        try? JSONDecoder().decode(CodexAccountSnapshot.self, from: payload)
    }

    private static func latestCapture(in snapshot: CodexAccountSnapshot) -> Date {
        max(
            snapshot.tokenActivity?.capturedAt ?? .distantPast,
            snapshot.resetCredits?.capturedAt ?? .distantPast
        )
    }
}

@Model
final class NotificationReceipt {
    @Attribute(.unique) var key: String
    var createdAt: Date

    init(key: String, createdAt: Date = Date()) {
        self.key = key
        self.createdAt = createdAt
    }
}

protocol HistoryStoring: Sendable {
    nonisolated var isPersistent: Bool { get }
    func record(_ snapshot: UsageSnapshot) async throws
    func latestSnapshot(for provider: ProviderID) async throws -> UsageSnapshot?
    func history(for provider: ProviderID, kind: UsageWindowKind, since: Date) async throws -> [HistoryPoint]
    func hasReceipt(_ key: String) async throws -> Bool
    func saveReceipt(_ key: String) async throws
    func prune(before cutoff: Date) async throws
    func clearHistory() async throws
    func clearReceipts() async throws
    func recordCodexAccount(_ snapshot: CodexAccountSnapshot) async throws
    func latestCodexAccount() async throws -> CodexAccountSnapshot?
}

@ModelActor
actor SwiftDataHistoryStore: HistoryStoring {
    nonisolated var isPersistent: Bool { true }

    static func makeLive(paths: AppPaths = .live()) throws -> SwiftDataHistoryStore {
        try HistoryStoreMigration.prepare(paths: paths)
        let schema = Schema([
            UsageRecord.self,
            LatestUsageRecord.self,
            LatestCodexAccountRecord.self,
            NotificationReceipt.self,
        ])
        let configuration = ModelConfiguration(
            "AgentsDeckHistory",
            schema: schema,
            url: paths.historyStore,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataHistoryStore(modelContainer: container)
    }

    func record(_ snapshot: UsageSnapshot) throws {
        let latestRecords = try modelContext.fetch(FetchDescriptor<LatestUsageRecord>())
        if let latest = latestRecords.first(where: { $0.providerRaw == snapshot.provider.rawValue }) {
            try latest.update(with: snapshot)
        } else {
            modelContext.insert(try LatestUsageRecord(snapshot: snapshot))
        }

        let records = try modelContext.fetch(FetchDescriptor<UsageRecord>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )).filter { $0.providerRaw == snapshot.provider.rawValue }
        let previous = records.first?.snapshot()
        if UsageAlgorithms.shouldPersist(snapshot, after: previous) {
            let key = Self.minuteKey(for: snapshot)
            if let existing = records.first(where: { $0.minuteKey == key }) {
                existing.update(with: snapshot)
            } else {
                modelContext.insert(UsageRecord(snapshot: snapshot, minuteKey: key))
            }
        }
        try modelContext.save()
    }

    func latestSnapshot(for provider: ProviderID) throws -> UsageSnapshot? {
        if let latest = try modelContext.fetch(FetchDescriptor<LatestUsageRecord>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )).first(where: { $0.providerRaw == provider.rawValue })?.snapshot() {
            return latest
        }
        return try modelContext.fetch(FetchDescriptor<UsageRecord>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )).first(where: { $0.providerRaw == provider.rawValue })?.snapshot()
    }

    func history(for provider: ProviderID, kind: UsageWindowKind, since: Date) throws -> [HistoryPoint] {
        try modelContext.fetch(FetchDescriptor<UsageRecord>(
            sortBy: [SortDescriptor(\.capturedAt)]
        )).filter { $0.providerRaw == provider.rawValue && $0.capturedAt >= since }.compactMap { record in
            let value: Double?
            let reset: Date?
            let duration: Int
            switch kind {
            case .fiveHour:
                value = record.fiveHourPercent
                reset = record.fiveHourReset
                duration = record.fiveHourDurationMinutes ?? kind.defaultDurationMinutes
            case .sevenDay:
                value = record.sevenDayPercent
                reset = record.sevenDayReset
                duration = record.sevenDayDurationMinutes ?? kind.defaultDurationMinutes
            }
            guard let value else { return nil }
            return HistoryPoint(
                id: UUID(),
                provider: provider,
                capturedAt: record.capturedAt,
                usedPercent: value,
                resetsAt: reset,
                windowKind: kind,
                durationMinutes: duration
            )
        }
    }

    func hasReceipt(_ key: String) throws -> Bool {
        try modelContext.fetch(FetchDescriptor<NotificationReceipt>()).contains { $0.key == key }
    }

    func saveReceipt(_ key: String) throws {
        guard try !modelContext.fetch(FetchDescriptor<NotificationReceipt>()).contains(where: { $0.key == key }) else { return }
        modelContext.insert(NotificationReceipt(key: key))
        try modelContext.save()
    }

    func prune(before cutoff: Date) throws {
        for record in try modelContext.fetch(FetchDescriptor<UsageRecord>()) where record.capturedAt < cutoff {
            modelContext.delete(record)
        }
        let receiptCutoff = cutoff.addingTimeInterval(-35 * 24 * 60 * 60)
        for receipt in try modelContext.fetch(FetchDescriptor<NotificationReceipt>()) where receipt.createdAt < receiptCutoff {
            modelContext.delete(receipt)
        }
        try modelContext.save()
    }

    func clearHistory() throws {
        try modelContext.delete(model: UsageRecord.self)
        try modelContext.delete(model: LatestUsageRecord.self)
        try modelContext.delete(model: LatestCodexAccountRecord.self)
        try modelContext.save()
    }

    func clearReceipts() throws {
        try modelContext.delete(model: NotificationReceipt.self)
        try modelContext.save()
    }

    func recordCodexAccount(_ snapshot: CodexAccountSnapshot) throws {
        let records = try modelContext.fetch(FetchDescriptor<LatestCodexAccountRecord>())
        if let existing = records.first(where: { $0.key == ProviderID.codex.rawValue }) {
            try existing.update(with: snapshot)
        } else {
            modelContext.insert(try LatestCodexAccountRecord(snapshot: snapshot))
        }
        try modelContext.save()
    }

    func latestCodexAccount() throws -> CodexAccountSnapshot? {
        try modelContext.fetch(FetchDescriptor<LatestCodexAccountRecord>())
            .first(where: { $0.key == ProviderID.codex.rawValue })?
            .snapshot()
    }

    private nonisolated static func minuteKey(for snapshot: UsageSnapshot) -> String {
        let minute = Int(snapshot.capturedAt.timeIntervalSince1970 / 60)
        return "\(snapshot.provider.rawValue):\(minute)"
    }
}

actor InMemoryHistoryStore: HistoryStoring {
    nonisolated var isPersistent: Bool { false }
    private var snapshots: [UsageSnapshot] = []
    private var latestSnapshots: [ProviderID: UsageSnapshot] = [:]
    private var receipts: [String: Date] = [:]
    private var codexAccount: CodexAccountSnapshot?

    func record(_ snapshot: UsageSnapshot) {
        latestSnapshots[snapshot.provider] = snapshot
        let prior = snapshots.last(where: { $0.provider == snapshot.provider })
        guard UsageAlgorithms.shouldPersist(snapshot, after: prior) else { return }
        let minute = Int(snapshot.capturedAt.timeIntervalSince1970 / 60)
        if let index = snapshots.firstIndex(where: {
            $0.provider == snapshot.provider && Int($0.capturedAt.timeIntervalSince1970 / 60) == minute
        }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
    }

    func latestSnapshot(for provider: ProviderID) -> UsageSnapshot? {
        latestSnapshots[provider]
    }

    func history(for provider: ProviderID, kind: UsageWindowKind, since: Date) -> [HistoryPoint] {
        snapshots.filter { $0.provider == provider && $0.capturedAt >= since }.compactMap { snapshot in
            guard let window = snapshot[kind] else { return nil }
            return HistoryPoint(
                id: UUID(),
                provider: provider,
                capturedAt: snapshot.capturedAt,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt,
                windowKind: kind,
                durationMinutes: window.durationMinutes
            )
        }.sorted { $0.capturedAt < $1.capturedAt }
    }

    func hasReceipt(_ key: String) -> Bool { receipts[key] != nil }
    func saveReceipt(_ key: String) { receipts[key] = Date() }
    func prune(before cutoff: Date) {
        snapshots.removeAll { $0.capturedAt < cutoff }
    }
    func clearHistory() {
        snapshots.removeAll()
        latestSnapshots.removeAll()
        codexAccount = nil
    }
    func clearReceipts() { receipts.removeAll() }
    func recordCodexAccount(_ snapshot: CodexAccountSnapshot) { codexAccount = snapshot }
    func latestCodexAccount() -> CodexAccountSnapshot? { codexAccount }
}

enum HistoryStoreFactory {
    static func makeLive(paths: AppPaths = .live()) -> any HistoryStoring {
        // The hosted test bundle launches the application target. Keep that launch
        // entirely away from the user's production Application Support directory.
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            return InMemoryHistoryStore()
        }

        do { return try SwiftDataHistoryStore.makeLive(paths: paths) }
        catch { return InMemoryHistoryStore() }
    }
}

enum HistoryStoreMigration {
    static func prepare(paths: AppPaths, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: paths.historyDirectory.path) {
            if fileManager.fileExists(atPath: paths.historyStore.path) { return }
            let contents = try fileManager.contentsOfDirectory(
                at: paths.historyDirectory,
                includingPropertiesForKeys: nil
            )
            guard !contents.isEmpty else { return }
            throw CocoaError(.fileReadCorruptFile)
        }

        guard fileManager.fileExists(atPath: paths.legacyHistoryStore.path),
              isAgentsDeckStore(paths.legacyHistoryStore)
        else {
            try fileManager.createDirectory(at: paths.historyDirectory, withIntermediateDirectories: false)
            return
        }

        let stagingDirectory = paths.applicationSupport.appending(
            path: ".HistoryMigration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let stagedStore = stagingDirectory.appending(path: "History.store")
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        var promoted = false
        defer {
            if !promoted { try? fileManager.removeItem(at: stagingDirectory) }
        }

        for suffix in storeSuffixes {
            let source = URL(filePath: paths.legacyHistoryStore.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(
                at: source,
                to: URL(filePath: stagedStore.path + suffix)
            )
        }

        let schema = Schema([
            UsageRecord.self,
            LatestUsageRecord.self,
            LatestCodexAccountRecord.self,
            NotificationReceipt.self,
        ])
        let configuration = ModelConfiguration(
            "AgentsDeckHistoryMigration",
            schema: schema,
            url: stagedStore,
            cloudKitDatabase: .none
        )
        _ = try ModelContainer(for: schema, configurations: [configuration])

        try fileManager.moveItem(at: stagingDirectory, to: paths.historyDirectory)
        promoted = true
        archiveLegacyStore(paths: paths, fileManager: fileManager)
    }

    private static let storeSuffixes = ["", "-wal", "-shm"]

    private static func isAgentsDeckStore(_ url: URL) -> Bool {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: url
        ),
        let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any]
        else { return false }
        let names = Set(hashes.keys)
        return names.contains("UsageRecord") && names.contains("NotificationReceipt")
    }

    private static func archiveLegacyStore(paths: AppPaths, fileManager: FileManager) {
        guard (try? fileManager.createDirectory(
            at: paths.backupsDirectory,
            withIntermediateDirectories: true
        )) != nil else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in storeSuffixes {
            let source = URL(filePath: paths.legacyHistoryStore.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let backup = paths.backupsDirectory.appending(
                path: "legacy-default-\(timestamp).store\(suffix)"
            )
            try? fileManager.moveItem(at: source, to: backup)
        }
    }
}
