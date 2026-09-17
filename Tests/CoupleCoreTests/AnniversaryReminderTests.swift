import Foundation
import Testing
import Domain
import Notification

@Test func anniversaryPlansRespectLeapDayLeadTimeAndDeletion() throws {
    let author = UUID(), id = UUID()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2025, month: 2, day: 20, hour: 12))!
    var state = SharedState()
    try state.apply(DomainEvent(objectID: id, author: author, sequence: 1, lamport: 1, createdAt: now,
        payload: .journal(.anniversary(AnniversaryContent(title: "私密标题", date: "2024-02-29")))), cycleOwner: nil)
    let plans = AnniversaryReminder.plans(records: state.journal.anniversaries, daysBefore: 7, now: now, calendar: calendar)
    #expect(plans.count == 4)
    #expect(plans[0].occurrence == "2025-02-28")
    #expect(plans[0].daysBefore == 7)
    #expect(CivilDate.string(plans[0].fireAt, calendar: calendar) == "2025-02-21")
    #expect(plans[1].daysBefore == 0)
    #expect(CivilDate.string(plans[1].fireAt, calendar: calendar) == "2025-02-28")
    try state.apply(DomainEvent(objectID: id, author: author, sequence: 2, lamport: 2, createdAt: now,
        payload: .journal(.anniversary(AnniversaryContent(title: "私密标题", date: "2024-02-29", deleted: true)))), cycleOwner: nil)
    #expect(AnniversaryReminder.plans(records: state.journal.anniversaries, daysBefore: 7, now: now, calendar: calendar).isEmpty)
}
