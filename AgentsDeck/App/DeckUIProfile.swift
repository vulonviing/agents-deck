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
        case .both: [.claude, .codex]
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
    var selectedAntigravityMetric: AntigravityMetricID?
    var antigravityGroupOrder = AntigravityQuotaGroup.defaultDisplayOrder
    var menuBarProviders: [ProviderID] = ProviderID.allCases
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
        case selectedAntigravityMetric
        case antigravityGroupOrder
        case menuBarProviders
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
        selectedAntigravityMetric = try values.decodeIfPresent(
            AntigravityMetricID.self,
            forKey: .selectedAntigravityMetric
        )
        antigravityGroupOrder = AntigravityQuotaGroup.normalizedDisplayOrder(
            (try? values.decode([AntigravityQuotaGroup].self, forKey: .antigravityGroupOrder)) ?? []
        )
        if let selected = try? values.decode([ProviderID].self, forKey: .menuBarProviders) {
            menuBarProviders = Self.normalizedMenuBarProviders(selected)
        } else if decodedVersion >= 2 {
            let legacy = try values.decodeIfPresent(
                MenuBarProviderSelection.self,
                forKey: .menuBarProviderSelection
            ) ?? .both
            menuBarProviders = Self.normalizedMenuBarProviders(legacy.providers + [.antigravity])
        } else {
            let provider = try values.decodeIfPresent(ProviderID.self, forKey: .selectedMenuBarProviderID)
            let mode = try values.decodeIfPresent(LegacyMenuBarDisplayMode.self, forKey: .menuBarDisplayMode)
                ?? .single
            menuBarProviders = switch (mode, provider) {
            case (.dual, _): ProviderID.allCases
            case (.single, .claude): [.claude]
            case (.single, .codex): [.codex]
            case (.single, .antigravity): [.antigravity]
            case (.single, nil): ProviderID.allCases
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
        try values.encodeIfPresent(selectedAntigravityMetric, forKey: .selectedAntigravityMetric)
        try values.encode(antigravityGroupOrder, forKey: .antigravityGroupOrder)
        try values.encode(menuBarProviders, forKey: .menuBarProviders)
        try values.encode(refreshCadence, forKey: .refreshCadence)
        try values.encode(menuBarItemVisible, forKey: .menuBarItemVisible)
        try values.encodeIfPresent(panelWidth, forKey: .panelWidth)
        try values.encodeIfPresent(panelHeight, forKey: .panelHeight)
        try values.encodeIfPresent(panelLayoutVersion, forKey: .panelLayoutVersion)
    }

    static func normalizedMenuBarProviders(_ proposed: [ProviderID]) -> [ProviderID] {
        let selected = Set(proposed)
        let result = ProviderID.allCases.filter { selected.contains($0) }
        return result.isEmpty ? ProviderID.allCases : result
    }

    mutating func moveAntigravityGroup(_ source: AntigravityQuotaGroup, to destination: AntigravityQuotaGroup) -> Bool {
        var order = AntigravityQuotaGroup.normalizedDisplayOrder(antigravityGroupOrder)
        guard source != destination,
              let sourceIndex = order.firstIndex(of: source),
              let destinationIndex = order.firstIndex(of: destination)
        else { return false }
        order.remove(at: sourceIndex)
        order.insert(source, at: destinationIndex)
        antigravityGroupOrder = order
        return true
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
