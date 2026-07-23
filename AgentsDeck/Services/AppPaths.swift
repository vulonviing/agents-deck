import Foundation

struct AppPaths: Sendable {
    let applicationSupport: URL

    var bridgeDirectory: URL { applicationSupport.appending(path: "Bridge", directoryHint: .isDirectory) }
    var claudeCapture: URL { bridgeDirectory.appending(path: "claude-usage.json") }
    var claudeManifest: URL { bridgeDirectory.appending(path: "claude-install.json") }
    var claudeProbeDirectory: URL { applicationSupport.appending(path: "Claude Probe", directoryHint: .isDirectory) }
    var logsDirectory: URL { applicationSupport.appending(path: "Logs", directoryHint: .isDirectory) }
    var historyDirectory: URL { applicationSupport.appending(path: "History", directoryHint: .isDirectory) }
    var historyStore: URL { historyDirectory.appending(path: "History.store") }
    var backupsDirectory: URL { applicationSupport.appending(path: "Backups", directoryHint: .isDirectory) }
    var legacyHistoryStore: URL {
        applicationSupport.deletingLastPathComponent().appending(path: "default.store")
    }

    static func live(fileManager: FileManager = .default) -> Self {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return Self(applicationSupport: base.appending(path: "Agents Deck", directoryHint: .isDirectory))
    }
}
