import Foundation
import Domain
import UserNotifications

public struct AnniversaryReminder: Equatable, Sendable {
    public let recordID: UUID
    public let occurrence: String
    public let daysBefore: Int
    public let fireAt: Date
    public var identifier: String { "anniversary.\(recordID.uuidString).\(occurrence).\(daysBefore)" }

    public static func plans(records: [UUID: JournalRecord<AnniversaryContent>], daysBefore: Int,
                             now: Date = Date(), calendar: Calendar = CivilDate.localCalendar) -> [AnniversaryReminder] {
        guard [0, 1, 3, 7].contains(daysBefore) else { return [] }
        let today = CivilDate.string(now, calendar: calendar)
        return records.values.filter { !$0.value.deleted }.flatMap { record -> [AnniversaryReminder] in
            var occurrence = record.value.nextOccurrence(today: today)
            var result: [AnniversaryReminder] = []
            for _ in 0..<(record.value.repeatsYearly ? 2 : 1) {
                guard let day = occurrence else { break }
                for lead in Set([0, daysBefore]) {
                    guard let alertDay = CivilDate.adding(days: -lead, to: day),
                          let date = CivilDate.parse(alertDay) else { continue }
                    let parts = CivilDate.calendar.dateComponents([.year, .month, .day], from: date)
                    var local = DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 9, minute: 0)
                    local.calendar = calendar; local.timeZone = calendar.timeZone
                    guard let fireAt = calendar.date(from: local), fireAt > now else { continue }
                    result.append(AnniversaryReminder(recordID: record.id, occurrence: day, daysBefore: lead, fireAt: fireAt))
                }
                occurrence = record.value.repeatsYearly ? CivilDate.adding(days: 1, to: day).flatMap { record.value.nextOccurrence(today: $0) } : nil
            }
            return result
        }.sorted { $0.fireAt == $1.fireAt ? $0.identifier < $1.identifier : $0.fireAt < $1.fireAt }
    }
}

public struct AnniversaryReminderScheduler {
    public init() {}
    public func reconcile(_ plans: [AnniversaryReminder], enabled: Bool, maxRequests: Int = 12) async throws -> Int {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let current = pending.filter { $0.identifier.hasPrefix("anniversary.") }
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let otherCount = pending.count - current.count
        let selected = enabled && authorized ? Array(plans.prefix(max(0, min(maxRequests, 64 - otherCount)))) : []
        let desired = Set(selected.map(\.identifier))
        let obsolete = current.map(\.identifier).filter { !desired.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter {
            $0.hasPrefix("anniversary.") && !desired.contains($0)
        })
        guard enabled else { return 0 }
        guard authorized else { throw SpaceError.unauthorized }
        for plan in selected {
            if let old = current.first(where: { $0.identifier == plan.identifier }),
               old.content.userInfo["fire_at"] as? Double == plan.fireAt.timeIntervalSince1970 { continue }
            let content = UNMutableNotificationContent()
            content.title = "我们"
            content.body = plan.daysBefore == 0 ? "今天有一个重要的日子" : "有一个重要的日子快到了"
            content.sound = .default
            content.userInfo = ["destination": "anniversary", "object_id": plan.recordID.uuidString,
                                "fire_at": plan.fireAt.timeIntervalSince1970]
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.fireAt)
            components.calendar = utc; components.timeZone = utc.timeZone
            try await center.add(UNNotificationRequest(identifier: plan.identifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
        return selected.count
    }
}
