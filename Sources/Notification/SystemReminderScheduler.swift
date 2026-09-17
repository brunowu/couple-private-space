import Foundation
import UserNotifications
import Domain

public struct SystemReminderScheduler: ReminderScheduler {
    public init() {}
    public func upsert(_ reminder: ReminderIntent) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { throw SpaceError.unauthorized }
        guard let fireAt = reminder.fireAt, fireAt > Date() else { throw SpaceError.expired }
        let pending = await center.pendingNotificationRequests()
        if let existing = pending.first(where: { $0.identifier == reminder.requestID.uuidString }),
           existing.trigger is UNCalendarNotificationTrigger,
           let stored = existing.content.userInfo["fire_at"] as? Double,
           stored == fireAt.timeIntervalSince1970,
           existing.content.userInfo["object_id"] as? String == reminder.wishID.uuidString { return }
        let content = UNMutableNotificationContent()
        content.title = "我们"
        content.body = "你有一个愿望提醒"
        content.userInfo = ["reminder_id": reminder.requestID.uuidString, "fire_at": fireAt.timeIntervalSince1970,
                            "destination": "wish", "object_id": reminder.wishID.uuidString]
        let trigger = try Self.calendarTrigger(for: fireAt)
        try await center.add(UNNotificationRequest(identifier: reminder.requestID.uuidString, content: content, trigger: trigger))
    }
    static func calendarTrigger(for fireAt: Date, now: Date = Date()) throws -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Rounding up could move a 21:59:59.x plan into quiet hours starting at 22:00.
        let instant = Date(timeIntervalSince1970: floor(fireAt.timeIntervalSince1970))
        guard instant > now else { throw SpaceError.expired }
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
    public func cancel(requestID: UUID) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [requestID.uuidString])
    }
}
