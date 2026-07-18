import Foundation

enum UsageValidationError: Error, Equatable {
    case invalidPercentage
    case invalidTimestamp
    case invalidDuration
}

enum UsageAlgorithms {
    static func normalizedPercentage(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw UsageValidationError.invalidPercentage
        }
        if value <= 100 { return value }
        if value <= 100.5 { return 100 }
        throw UsageValidationError.invalidPercentage
    }

    static func validResetDate(epochSeconds: Double?, now: Date = Date()) -> Date? {
        guard let epochSeconds, epochSeconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: epochSeconds)
        let earliest = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let latest = now.addingTimeInterval(370 * 24 * 60 * 60)
        return (earliest...latest).contains(date) ? date : nil
    }

    static func normalizedDurationMinutes(_ value: Int?) throws -> Int? {
        guard let value else { return nil }
        guard (1...525_600).contains(value) else { throw UsageValidationError.invalidDuration }
        return value
    }

    static func isFresh(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        let maximumAge: TimeInterval = snapshot.provider == .claude ? 10 * 60 : 150
        return now.timeIntervalSince(snapshot.capturedAt) <= maximumAge
    }

    static func criticalProvider(
        in states: [ProviderViewState],
        keeping current: ProviderID? = nil,
        now: Date = Date()
    ) -> ProviderViewState? {
        let candidates = states.filter { state in
            guard let snapshot = state.snapshot,
                  snapshot.shortWindow != nil,
                  isFresh(snapshot, now: now)
            else { return false }
            return true
        }
        guard let highest = candidates.sorted(by: { lhs, rhs in
            let lhsValue = lhs.snapshot?.shortWindow?.usedPercent ?? -1
            let rhsValue = rhs.snapshot?.shortWindow?.usedPercent ?? -1
            if lhsValue == rhsValue { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhsValue > rhsValue
        }).first else { return nil }

        if let current,
           let retained = candidates.first(where: { $0.provider == current }),
           let currentValue = retained.snapshot?.shortWindow?.usedPercent,
           let highestValue = highest.snapshot?.shortWindow?.usedPercent,
           highestValue - currentValue < 1 {
            return retained
        }
        return highest
    }

    static func shouldPersist(
        _ snapshot: UsageSnapshot,
        after previous: UsageSnapshot?,
        heartbeat: TimeInterval = 15 * 60
    ) -> Bool {
        guard let previous else { return true }
        if snapshot.capturedAt.timeIntervalSince(previous.capturedAt) >= heartbeat { return true }
        if snapshot.billing != previous.billing { return true }

        for kind in UsageWindowKind.allCases {
            let current = snapshot[kind]
            let old = previous[kind]
            if current?.resetsAt != old?.resetsAt { return true }
            if current?.durationMinutes != old?.durationMinutes { return true }
            if let current, let old, abs(current.usedPercent - old.usedPercent) >= 1 { return true }
            if (current == nil) != (old == nil) { return true }
        }
        return false
    }
}
