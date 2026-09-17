import Foundation
import Testing
import Domain
@testable import Notification

@Test func quietHoursRespectOvernightBoundariesAndRejectWholeDaySilence() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13))!
    let quiet = QuietHours(enabled: true, startHour: 22, endHour: 8)
    #expect(!quiet.allows(start.addingTimeInterval(7 * 3600 + 3599), calendar: calendar))
    #expect(quiet.allows(start.addingTimeInterval(8 * 3600), calendar: calendar))
    #expect(!quiet.allows(start.addingTimeInterval(22 * 3600), calendar: calendar))
    let allowed = try quiet.allowedIntervals(start: start, days: 1, calendar: calendar)
    #expect(allowed == [DateInterval(start: start.addingTimeInterval(8 * 3600), duration: 14 * 3600)])
    #expect(throws: SpaceError.invalidInput) { try QuietHours(enabled: true, startHour: 8, endHour: 8).validate() }
    #expect(throws: SpaceError.invalidInput) { try quiet.allowedIntervals(start: start, days: 0) }
}

@Test func quietHourSamplingHandlesBothDaylightSavingTransitions() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let quiet = QuietHours(enabled: true)
    for (month, day, hours) in [(3, 29, 23), (10, 25, 25)] {
        let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        let full = try QuietHours().allowedIntervals(start: start, days: 1, calendar: calendar)
        #expect(full.reduce(0) { $0 + $1.duration } == Double(hours * 3600))
        let allowed = try quiet.allowedIntervals(start: start, days: 1, calendar: calendar)
        #expect(allowed.reduce(0) { $0 + $1.duration } == 14 * 3600)
        for sample in [0.0, 0.25, 0.5, 0.999999] {
            let reminder = try ReminderPlanner().plan(ReminderIntent(wishID: UUID(), receivedAt: start), allowed: allowed, sample: sample)
            #expect(quiet.allows(try #require(reminder.fireAt), calendar: calendar))
        }
    }
}

@Test func daytimeQuietHoursKeepBothAllowedSegmentsAndClipPartialHour() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
    let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 7, minute: 35))!
    let quiet = QuietHours(enabled: true, startHour: 12, endHour: 14)
    let intervals = try quiet.allowedIntervals(start: start, days: 1, calendar: calendar)
    #expect(intervals.count == 2)
    #expect(intervals.first?.start == start)
    #expect(intervals.reduce(0) { $0 + $1.duration } == 22 * 3600)
    #expect(intervals.allSatisfy { quiet.allows($0.start, calendar: calendar) && quiet.allows($0.end.addingTimeInterval(-1), calendar: calendar) })
}

@Test func systemTriggerCannotRoundAllowedTimeIntoQuietHour() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let future = calendar.date(byAdding: .day, value: 2, to: Date())!
    let start = calendar.startOfDay(for: future)
    let allowed = try QuietHours(enabled: true).allowedIntervals(start: start, days: 1, calendar: calendar)
    let plan = try ReminderPlanner().plan(ReminderIntent(wishID: UUID(), receivedAt: start), allowed: allowed, sample: 0.9999999)
    let trigger = try SystemReminderScheduler.calendarTrigger(for: #require(plan.fireAt))
    let actual = try #require(trigger.nextTriggerDate())
    #expect(QuietHours(enabled: true).allows(actual, calendar: calendar))
    #expect(actual < allowed[0].end)
    #expect(trigger.dateComponents.timeZone?.secondsFromGMT() == 0)
}
