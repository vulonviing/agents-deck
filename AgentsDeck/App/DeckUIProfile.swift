import Foundation

enum MenuBarProviderSelection: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case both

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .both: "Both"
        }
    }

    var providers: [ProviderID] {
        switch self {
        case .claude: [.claude]
        case .codex: [.codex]
        case .both: ProviderID.allCases
        }
    }
}

enum RefreshCadence: String, Codable, CaseIterable, Sendable {
    case oneToThreeMinutes
    case threeToFiveMinutes
    case fourToSixMinutes

    var secondsRange: ClosedRange<Int> {
        switch self {
        case .oneToThreeMinutes: 60...180
        case .threeToFiveMinutes: 180...300
        case .fourToSixMinutes: 240...360
        }
    }

    var displayName: String {
        switch self {
        case .oneToThreeMinutes: "1–3 min"
        case .threeToFiveMinutes: "3–5 min"
        case .fourToSixMinutes: "4–6 min"
        }
    }

    func nextDelaySeconds<R: RandomNumberGenerator>(using generator: inout R) -> Int {
        Int.random(in: secondsRange, using: &generator)
    }
}

struct DeckUIProfile: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var selectedUsageWindowByProvider: [ProviderID: UsageWindowKind] = [:]
    var menuBarProviderSelection: MenuBarProviderSelection = .both
    var refreshCadence: RefreshCadence = .oneToThreeMinutes
    var menuBarItemVisible = true
    var panelWidth: Double?
    var panelHeight: Double?
    var panelLayoutVersion: Int?

    static let empty = Self()
}

extension DeckUIProfile {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedUsageWindowByProvider
        case menuBarProviderSelection
        case refreshCadence
        case menuBarItemVisible
        case panelWidth
        case panelHeight
        case panelLayoutVersion
        case selectedMenuBarProviderID
        case menuBarDisplayMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = Self.currentSchemaVersion
        selectedUsageWindowByProvider = try values.decodeIfPresent(
            [ProviderID: UsageWindowKind].self,
            forKey: .selectedUsageWindowByProvider
        ) ?? [:]
        if decodedVersion >= 2 {
            menuBarProviderSelection = try values.decodeIfPresent(
                MenuBarProviderSelection.self,
                forKey: .menuBarProviderSelection
            ) ?? .both
        } else {
            let provider = try values.decodeIfPresent(ProviderID.self, forKey: .selectedMenuBarProviderID)
            let mode = try values.decodeIfPresent(LegacyMenuBarDisplayMode.self, forKey: .menuBarDisplayMode)
                ?? .single
            menuBarProviderSelection = switch (mode, provider) {
            case (.dual, _): .both
            case (.single, .claude): .claude
            case (.single, .codex): .codex
            case (.single, nil): .both
            }
        }
        refreshCadence = try values.decodeIfPresent(RefreshCadence.self, forKey: .refreshCadence) ?? .oneToThreeMinutes
        menuBarItemVisible = try values.decodeIfPresent(Bool.self, forKey: .menuBarItemVisible) ?? true
        panelWidth = try values.decodeIfPresent(Double.self, forKey: .panelWidth)
        panelHeight = try values.decodeIfPresent(Double.self, forKey: .panelHeight)
        panelLayoutVersion = try values.decodeIfPresent(Int.self, forKey: .panelLayoutVersion)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(selectedUsageWindowByProvider, forKey: .selectedUsageWindowByProvider)
        try values.encode(menuBarProviderSelection, forKey: .menuBarProviderSelection)
        try values.encode(refreshCadence, forKey: .refreshCadence)
        try values.encode(menuBarItemVisible, forKey: .menuBarItemVisible)
        try values.encodeIfPresent(panelWidth, forKey: .panelWidth)
        try values.encodeIfPresent(panelHeight, forKey: .panelHeight)
        try values.encodeIfPresent(panelLayoutVersion, forKey: .panelLayoutVersion)
    }
}

private enum LegacyMenuBarDisplayMode: String, Codable {
    case single
    case dual
}

struct DeckUIProfileStore {
    private static let profileKey = "ui.profile.v1"
    private static let legacyPanelWidthKey = "popover.width"
    private static let legacyPanelHeightKey = "popover.height"
    private static let legacyPanelLayoutVersionKey = "popover.layoutVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DeckUIProfile {
        if let data = defaults.data(forKey: Self.profileKey),
           let profile = try? JSONDecoder().decode(DeckUIProfile.self, from: data),
           profile.schemaVersion == DeckUIProfile.currentSchemaVersion {
            return profile
        }

        let migrated = migratedLegacyProfile()
        if migrated != .empty {
            save(migrated)
        }
        return migrated
    }

    func save(_ profile: DeckUIProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Self.profileKey)
    }

    private func migratedLegacyProfile() -> DeckUIProfile {
        let hasLegacyPanelSize = defaults.object(forKey: Self.legacyPanelWidthKey) != nil
            || defaults.object(forKey: Self.legacyPanelHeightKey) != nil
            || defaults.object(forKey: Self.legacyPanelLayoutVersionKey) != nil
        guard hasLegacyPanelSize else { return .empty }

        return DeckUIProfile(
            panelWidth: defaults.double(forKey: Self.legacyPanelWidthKey),
            panelHeight: defaults.double(forKey: Self.legacyPanelHeightKey),
            panelLayoutVersion: defaults.integer(forKey: Self.legacyPanelLayoutVersionKey)
        )
    }
}
