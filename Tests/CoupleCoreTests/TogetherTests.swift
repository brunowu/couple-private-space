import Foundation
import Testing
import Domain
import Sync

@Test func anniversaryCalendarHandlesLeapDaysPastDatesAndYearBoundaries() throws {
    let leap = AnniversaryContent(title: "纪念", date: "2024-02-29")
    #expect(leap.nextOccurrence(today: "2025-02-28") == "2025-02-28")
    #expect(leap.nextOccurrence(today: "2025-03-01") == "2026-02-28")
    #expect(leap.nextOccurrence(today: "2028-02-01") == "2028-02-29")
    #expect(AnniversaryContent(title: "元旦", date: "2020-01-01").nextOccurrence(today: "2026-12-31") == "2027-01-01")
    #expect(AnniversaryContent(title: "旅行", date: "2026-01-01", repeatsYearly: false).nextOccurrence(today: "2026-01-02") == nil)
    #expect(AnniversaryContent(title: "未来", date: "2030-01-01").nextOccurrence(today: "2026-01-01") == "2030-01-01")
    #expect(CivilDate.distance(from: "2026-03-28", to: "2026-03-30") == 2)
    #expect(throws: SpaceError.invalidInput) { try AnniversaryContent(title: "无效", date: "2026-02-29").validate() }
}

@Test func anniversaryEditsAndDeletionConvergeWithoutResurrectingOldValues() throws {
    let a = UUID(), b = UUID(), id = UUID(), now = Date()
    let create = DomainEvent(objectID: id, author: a, sequence: 1, lamport: 1, createdAt: now, payload: .journal(.anniversary(AnniversaryContent(title: "相识", date: "2020-01-02"))))
    let edit = DomainEvent(objectID: id, author: b, sequence: 1, lamport: 2, createdAt: now, payload: .journal(.anniversary(AnniversaryContent(title: "相识那天", date: "2020-01-03"))))
    let delete = DomainEvent(objectID: id, author: a, sequence: 2, lamport: 3, createdAt: now, payload: .journal(.anniversary(AnniversaryContent(title: "相识那天", date: "2020-01-03", deleted: true))))
    var x = SharedState(), y = SharedState()
    for event in [create, edit, delete] { try x.apply(event, cycleOwner: nil) }
    for event in [delete, create, edit] { try y.apply(event, cycleOwner: nil) }
    #expect(x == y); #expect(x.journal.anniversaries[id]?.value.deleted == true)
    #expect(create.schemaVersion == 4)
    var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(JournalState())) as? [String: Any])
    oldJSON.removeValue(forKey: "anniversaryStorage")
    let legacy = try JSONDecoder().decode(JournalState.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    #expect(legacy.anniversaries.isEmpty)
}

@Test func cycleSelectiveProjectionExcludesPrivateFieldsAndValidatesDates() throws {
    var entry = CycleEntry(record: PrivateCycleRecord(startDate: "2026-09-01", endDate: "2026-09-05", note: "private-note"), usualLength: 30, shareEstimate: true)
    try entry.validate(today: "2026-09-13")
    let projection = entry.projection(owner: UUID(), generation: 1)
    try projection.validate()
    #expect(projection.startDate == nil && projection.endDate == nil && projection.stage == nil)
    #expect(projection.estimatedNextDate == "2026-10-01")
    let bytes = try JSONEncoder().encode(projection)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("private-note"))
    entry.record.endDate = "2026-08-31"
    #expect(throws: SpaceError.invalidInput) { try entry.validate(today: "2026-09-13") }
    entry.record.endDate = nil; entry.record.startDate = "2026-09-14"
    #expect(throws: SpaceError.invalidInput) { try entry.validate(today: "2026-09-13") }
}

@Test func privateCycleAndRevocationAreAtomicAndEncryptedSyncNeverSharesNotes() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = CivilDate.parse("2026-09-13")!.addingTimeInterval(43_200)
    _ = try await c.a.create(.message(text: "建立会话"), now: now)
    try await c.a.sync(using: c.relay, now: now); try await c.b.sync(using: c.relay, now: now)
    var entry = CycleEntry(record: PrivateCycleRecord(startDate: "2026-09-01", note: "only-on-owner"), shareDates: true, shareEstimate: true, shareStage: true)
    try await c.b.saveCycle(entry, now: now)
    let shared = try #require(await c.b.state().cycle)
    try await c.b.sync(using: c.relay, now: now); try await c.a.sync(using: c.relay, now: now)
    #expect(try await c.a.state().cycle == shared)
    #expect(try c.dbA.entries("privateCycle").isEmpty)
    for table in ["pending", "events", "app"] {
        #expect(try c.dbA.entries(table).allSatisfy { !String(decoding: $0.1, as: UTF8.self).contains("only-on-owner") })
    }
    do { try await c.a.saveCycle(entry, now: now); Issue.record("peer edited private cycle") }
    catch { #expect(error as? SpaceError == .unauthorized) }
    entry.shareDates = false; entry.shareEstimate = false; entry.shareStage = false
    c.dbB.failNextCommit = true
    do { try await c.b.saveCycle(entry, now: now); Issue.record("expected rollback") }
    catch { #expect(error as? SpaceError == .injectedFailure) }
    #expect(try await c.b.privateCycle()?.shareDates == true)
    #expect(try await c.b.state().cycle == shared)
    try await c.b.saveCycle(entry, now: now)
    try await c.b.sync(using: c.relay, now: now); try await c.a.sync(using: c.relay, now: now)
    #expect(try await c.a.state().cycle?.revoked == true)
    var state = try await c.a.state()
    try state.apply(DomainEvent(author: c.pairB.localID, sequence: 100, lamport: 100, createdAt: now, payload: .cycle(shared)), cycleOwner: c.pairB.localID)
    #expect(state.cycle?.revoked == true)
    let reopened = try SyncCoordinator(db: c.dbB, cipher: c.cryptoB, pair: c.pairB)
    #expect(try await reopened.privateCycle() == entry)
}

@Test func anniversariesUseEncryptedDeliveryAndPeerCanEdit() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let id = AnniversaryContent.relationshipID
    _ = try await c.a.create(.journal(.anniversary(AnniversaryContent(title: "关系开始日", date: "2020-09-01"))), objectID: id)
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    let edit = try await c.b.create(.journal(.anniversary(AnniversaryContent(title: "关系开始日", date: "2020-09-02"))), objectID: id)
    try await c.b.sync(using: c.relay); try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.a.state().journal.anniversaries[id]?.value.date == "2020-09-02")
    #expect(try await c.b.delivery(edit.id) == .delivered)
}
