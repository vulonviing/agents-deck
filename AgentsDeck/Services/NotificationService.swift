import Foundation
import UserNotifications

actor NotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func evaluate(_ snapshot: UsageSnapshot, receipts: any HistoryStoring) async {
        guard snapshot.provider != .antigravity else { return }
        guard UsageAlgorithms.isFresh(snapshot) else { return }
        for kind in UsageWindowKind.allCases {
            guard let window = snapshot[kind], let reset = window.resetsAt else { continue }
            let reached = NotificationPolicy.reachedThresholds(for: window.usedPercent)
            guard let highest = reached.max() else { continue }

            let highestKey = NotificationPolicy.receiptKey(snapshot.provider, kind, reset, highest)
            guard (try? await receipts.hasReceipt(highestKey)) == false else { continue }

            let content = UNMutableNotificationContent()
            content.title = "\(snapshot.provider.displayName) usage at \(highest)%"
            content.body = "The \(window.displayName) window is at \(Int(window.usedPercent.rounded()))%."
            content.sound = .default
            let request = UNNotificationRequest(identifier: highestKey, content: content, trigger: nil)
            do {
                try await center.add(request)
                for threshold in reached {
                    try await receipts.saveReceipt(NotificationPolicy.receiptKey(snapshot.provider, kind, reset, threshold))
                }
            } catch {
                return
            }
        }
    }

}

enum NotificationPolicy {
    static func reachedThresholds(for percentage: Double) -> [Int] {
        [80, 95].filter { percentage >= Double($0) }
    }

    static func receiptKey(_ provider: ProviderID, _ kind: UsageWindowKind, _ reset: Date, _ threshold: Int) -> String {
        "\(provider.rawValue):\(kind.rawValue):\(Int(reset.timeIntervalSince1970)):\(threshold)"
    }
}
