import Foundation

enum UsageRingPosition: Equatable, Sendable {
    case inner
    case outer
}

enum UsageRingAccent: Equatable, Sendable {
    case shortWindow
    case longWindow
}

struct UsageRingDescriptor: Identifiable, Equatable, Sendable {
    var id: UsageWindowKind { window.kind }
    let window: UsageWindow
    let position: UsageRingPosition
    let accent: UsageRingAccent
}

enum UsageRingLayout {
    static func descriptors(for snapshot: UsageSnapshot) -> [UsageRingDescriptor] {
        let windows = snapshot.sortedWindows
        guard windows.count > 1 else {
            return windows.map {
                UsageRingDescriptor(
                    window: $0,
                    position: .outer,
                    accent: $0.isShortWindow ? .shortWindow : .longWindow
                )
            }
        }

        guard let shortest = windows.first, let longest = windows.last else { return [] }
        return [
            UsageRingDescriptor(window: shortest, position: .inner, accent: .shortWindow),
            UsageRingDescriptor(window: longest, position: .outer, accent: .longWindow)
        ]
    }

    static func defaultSelectedKind(in descriptors: [UsageRingDescriptor]) -> UsageWindowKind? {
        descriptors.first(where: { $0.id == .fiveHour })?.id ?? descriptors.first?.id
    }

    static func reconciledSelection(
        _ selection: UsageWindowKind?,
        in descriptors: [UsageRingDescriptor]
    ) -> UsageWindowKind? {
        if let selection, descriptors.contains(where: { $0.id == selection }) { return selection }
        return defaultSelectedKind(in: descriptors)
    }
}

struct AntigravityMetricID: Codable, Hashable, Identifiable, Sendable {
    let group: AntigravityQuotaGroup
    let kind: UsageWindowKind

    var id: String { "\(group.rawValue).\(kind.rawValue)" }
}

struct AntigravityMetricDescriptor: Identifiable, Equatable, Sendable {
    let id: AntigravityMetricID
    let state: QuotaWindowState?
    let colorIndex: Int

    var window: UsageWindow? {
        if case let .available(window) = state { return window }
        return nil
    }
}

enum AntigravityMetricLayout {
    static let metrics: [AntigravityMetricID] = [
        .init(group: .geminiModels, kind: .fiveHour),
        .init(group: .geminiModels, kind: .sevenDay),
        .init(group: .claudeAndGPTModels, kind: .fiveHour),
        .init(group: .claudeAndGPTModels, kind: .sevenDay),
        .init(group: .gemini4Argon, kind: .sevenDay)
    ]

    static func descriptors(for snapshot: UsageSnapshot) -> [AntigravityMetricDescriptor] {
        metrics.enumerated().map { index, metric in
            AntigravityMetricDescriptor(
                id: metric,
                state: snapshot.groupedWindows[metric.group]?[metric.kind],
                colorIndex: index
            )
        }
    }

}
