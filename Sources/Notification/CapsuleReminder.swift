import Foundation
import Domain
import UserNotifications

public struct CapsuleReminder: Equatable, Sendable {
    public let rootID: UUID
    public let fireAt: Date
    public var identifier: String { "capsule.\(rootID.uuidString)" }
    public static func eligible(journal: JournalState, opened: Set<UUID>) -> [CapsuleReminder] {
        journal.capsules.values.filter { root in
            root.value.companionOf == nil && journal.contributions(to: root.id).contains {
                !journal.isCancelled($0) && !opened.contains($0.id)
            }
        }.map { CapsuleReminder(rootID: $0.id, fireAt: $0.value.opensAt) }
            .sorted { $0.fireAt == $1.fireAt ? $0.rootID.uuidString < $1.rootID.uuidString : $0.fireAt < $1.fireAt }
    }
}

public struct CapsuleReminderScheduler {
    public init() {}
    public func reconcile(_ plans: [CapsuleReminder], enabled: Bool, now: Date = Date()) async throws -> Int {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let eligible = Set(enabled ? plans.map(\.identifier) : [])
        let obsolete = Set(pending.map(\.identifier) + delivered.map { $0.request.identifier })
            .filter { $0.hasPrefix("capsule.") && !eligible.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: Array(obsolete))
        center.removeDeliveredNotifications(withIdentifiers: Array(obsolete))
        guard enabled else { return 0 }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { throw SpaceError.unauthorized }
        // 30 wishes + 12 anniversaries + 22 capsules fit iOS's 64 pending requests.
        let available = min(22, max(0, 64 - pending.filter { !$0.identifier.hasPrefix("capsule.") }.count))
        let future = Array(plans.filter { ceil($0.fireAt.timeIntervalSince1970) > now.timeIntervalSince1970 }.prefix(available))
        let scheduled = Set(future.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.identifier.hasPrefix("capsule.") && !scheduled.contains($0.identifier)
        }.map(\.identifier))
        for plan in future {
            if pending.contains(where: { $0.identifier == plan.identifier && ($0.content.userInfo["fire_at"] as? Double) == plan.fireAt.timeIntervalSince1970 }) { continue }
            let content = UNMutableNotificationContent()
            content.title = "我们"
            content.body = "你有一个时间胶囊提醒"
            content.sound = .default
            content.userInfo = ["destination": "capsule", "object_id": plan.rootID.uuidString, "fire_at": plan.fireAt.timeIntervalSince1970]
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let instant = Date(timeIntervalSince1970: ceil(plan.fireAt.timeIntervalSince1970))
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
            components.calendar = calendar; components.timeZone = calendar.timeZone
            try await center.add(UNNotificationRequest(identifier: plan.identifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
        return future.count
    }
}
