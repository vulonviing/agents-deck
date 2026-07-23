import Foundation

struct ClaudeInstallManifest: Codable, Sendable {
    let installedCommand: String
    let originalStatusLineJSON: Data?
    let installedAt: Date

    init(installedCommand: String, originalStatusLineJSON: Data?, installedAt: Date) {
        self.installedCommand = installedCommand
        self.originalStatusLineJSON = originalStatusLineJSON
        self.installedAt = installedAt
    }

    private enum CodingKeys: String, CodingKey {
        case installedCommand, originalStatusLineJSON, installedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        installedCommand = try values.decode(String.self, forKey: .installedCommand)
        originalStatusLineJSON = try values.decodeIfPresent(Data.self, forKey: .originalStatusLineJSON)
        installedAt = try values.decode(Date.self, forKey: .installedAt)
    }
}

enum ClaudeSettingsError: Error, Equatable {
    case malformedSettings
    case changedSinceInstall
    case missingManifest
}

struct ClaudeSettingsInstaller {
    private let paths: AppPaths
    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        paths: AppPaths = .live(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    var settingsURL: URL {
        homeDirectory.appending(path: ".claude/settings.json")
    }

    var bridgeURL: URL {
        paths.bridgeDirectory.appending(path: "claude-statusline-bridge")
    }

    func isInstalled() -> Bool {
        guard let root = try? readSettings(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { return false }
        return command == shellQuote(bridgeURL.path)
    }

    func install(now: Date = Date()) throws {
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.bridgeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var root = try readSettings()
        let original = root["statusLine"]
        if let current = original as? [String: Any],
           current["command"] as? String == shellQuote(bridgeURL.path) {
            return
        }

        if fileManager.fileExists(atPath: settingsURL.path) {
            try createBackup(now: now)
        }

        let originalJSON: Data?
        if let original {
            guard JSONSerialization.isValidJSONObject(original) else {
                throw ClaudeSettingsError.malformedSettings
            }
            originalJSON = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        } else {
            originalJSON = nil
        }
        let originalCommand = (original as? [String: Any])?["command"] as? String
        let installedCommand = shellQuote(bridgeURL.path)
        let manifest = ClaudeInstallManifest(
            installedCommand: installedCommand,
            originalStatusLineJSON: originalJSON,
            installedAt: now
        )

        try writePrivate(Data(bridgeScript(originalCommand: originalCommand).utf8), to: bridgeURL, permissions: 0o700)
        let manifestData = try JSONEncoder().encode(manifest)
        try writePrivate(manifestData, to: paths.claudeManifest, permissions: 0o600)

        root["statusLine"] = ["type": "command", "command": installedCommand]
        do {
            try writeSettings(root)
        } catch {
            try? fileManager.removeItem(at: bridgeURL)
            try? fileManager.removeItem(at: paths.claudeManifest)
            throw error
        }
        try pruneBackups(keeping: 5)
    }

    @discardableResult
    func uninstall() throws -> Bool {
        guard fileManager.fileExists(atPath: paths.claudeManifest.path) else {
            throw ClaudeSettingsError.missingManifest
        }
        let manifest = try JSONDecoder().decode(
            ClaudeInstallManifest.self,
            from: Data(contentsOf: paths.claudeManifest)
        )
        var root = try readSettings()
        let currentCommand = (root["statusLine"] as? [String: Any])?["command"] as? String
        guard currentCommand == manifest.installedCommand else {
            throw ClaudeSettingsError.changedSinceInstall
        }

        try createBackup(now: Date())
        if let originalData = manifest.originalStatusLineJSON {
            root["statusLine"] = try JSONSerialization.jsonObject(with: originalData)
        } else {
            root.removeValue(forKey: "statusLine")
        }
        try writeSettings(root)
        try? fileManager.removeItem(at: bridgeURL)
        try? fileManager.removeItem(at: paths.claudeManifest)
        try? fileManager.removeItem(at: paths.claudeCapture)
        // Best-effort cleanup of a capture file from the now-removed session-details feature,
        // in case this Mac had it enabled before the feature was retired.
        try? fileManager.removeItem(at: paths.bridgeDirectory.appending(path: "claude-session-details.json"))
        return true
    }

    private func readSettings() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSettingsError.malformedSettings
        }
        return root
    }

    private func writeSettings(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ClaudeSettingsError.malformedSettings
        }
        let attributes = try? fileManager.attributesOfItem(atPath: settingsURL.path)
        let existingPermissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writePrivate(data, to: settingsURL, permissions: existingPermissions)
    }

    private func writePrivate(_ data: Data, to url: URL, permissions: Int) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func createBackup(now: Date) throws {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = settingsURL.deletingLastPathComponent()
        let stem = "settings.json.agents-deck.\(formatter.string(from: now))"
        var backup = directory.appending(path: "\(stem).backup")
        var suffix = 1
        while fileManager.fileExists(atPath: backup.path) {
            backup = directory.appending(path: "\(stem)-\(suffix).backup")
            suffix += 1
        }
        try fileManager.copyItem(at: settingsURL, to: backup)
    }

    private func pruneBackups(keeping count: Int) throws {
        let directory = settingsURL.deletingLastPathComponent()
        let backups = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("settings.json.agents-deck.") }
        let sorted = backups.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for backup in sorted.dropFirst(count) {
            try fileManager.removeItem(at: backup)
        }
    }

    private func bridgeScript(originalCommand: String?) -> String {
        let original = Data((originalCommand ?? "").utf8).base64EncodedString()
        let capturePath = shellQuote(paths.claudeCapture.path)
        return """
        #!/bin/zsh
        umask 077
        capture_path=\(capturePath)
        original_command="$(/usr/bin/printf '%s' '\(original)' | /usr/bin/base64 -D 2>/dev/null)"
        payload="$(/bin/cat)"

        if [[ -n "$original_command" ]]; then
          /usr/bin/printf '%s' "$payload" | /bin/zsh -lc "$original_command" || true
        fi

        captured_at="$(/bin/date +%s)"

        rate_limits="$(/usr/bin/printf '%s' "$payload" | /usr/bin/plutil -extract rate_limits json -o - -- - 2>/dev/null)"
        if [[ -n "$rate_limits" ]]; then
          cost="$(/usr/bin/printf '%s' "$payload" | /usr/bin/plutil -extract cost.total_cost_usd raw -o - -- - 2>/dev/null)"
          temporary="${capture_path}.tmp.$$"

          if [[ "$cost" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
            /usr/bin/printf '{"captured_at":%s,"rate_limits":%s,"session_cost_usd":%s}\n' "$captured_at" "$rate_limits" "$cost" > "$temporary"
          else
            /usr/bin/printf '{"captured_at":%s,"rate_limits":%s}\n' "$captured_at" "$rate_limits" > "$temporary"
          fi
          /bin/chmod 600 "$temporary"
          /bin/mv -f "$temporary" "$capture_path"
        fi

        if [[ -z "$original_command" && -n "$rate_limits" ]]; then
          used="$(/usr/bin/printf '%s' "$rate_limits" | /usr/bin/plutil -extract five_hour.used_percentage raw -o - -- - 2>/dev/null)"
          [[ -n "$used" ]] && /usr/bin/printf 'Claude · %s%%\n' "$used"
        fi
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
