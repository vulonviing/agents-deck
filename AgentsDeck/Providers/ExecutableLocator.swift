import Foundation

struct ExecutableLocator {
    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func locate(_ provider: ProviderID, customPath: String? = nil) -> URL? {
        let executableName = provider.rawValue
        var candidates: [URL] = []
        if let customPath, !customPath.isEmpty {
            candidates.append(URL(filePath: customPath))
        }
        candidates += [
            URL(filePath: "/opt/homebrew/bin/\(executableName)"),
            URL(filePath: "/usr/local/bin/\(executableName)"),
            homeDirectory.appending(path: ".local/bin/\(executableName)"),
            homeDirectory.appending(path: ".\(executableName)/bin/\(executableName)"),
            homeDirectory.appending(path: ".claude/local/claude")
        ]

        return candidates.first(where: isExecutableFile)?.resolvingSymlinksInPath()
    }

    func isExecutableFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true || values.isSymbolicLink == true
        else { return false }
        return fileManager.isExecutableFile(atPath: url.path)
    }
}
