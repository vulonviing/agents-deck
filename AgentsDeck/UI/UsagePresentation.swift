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
        descriptors.min { lhs, rhs in
            if lhs.window.usedPercent != rhs.window.usedPercent {
                return lhs.window.usedPercent < rhs.window.usedPercent
            }
            if lhs.window.durationMinutes != rhs.window.durationMinutes {
                return lhs.window.durationMinutes < rhs.window.durationMinutes
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }?.id
    }

    static func reconciledSelection(
        _ selection: UsageWindowKind?,
        in descriptors: [UsageRingDescriptor]
    ) -> UsageWindowKind? {
        if let selection, descriptors.contains(where: { $0.id == selection }) { return selection }
        return defaultSelectedKind(in: descriptors)
    }
}
