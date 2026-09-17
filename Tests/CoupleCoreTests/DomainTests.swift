import Foundation
import Testing
import Domain
import Notification
import Transport

@Test func wishCompletionUsesWinningOperationTimeAcrossArrivalOrdersAndRestarts() throws {
    let author = UUID(), id = UUID(), date = Date(timeIntervalSince1970: 1_000)
    let events = [
        DomainEvent(objectID: id, author: author, sequence: 1, lamport: 1, createdAt: date, payload: .wishCreated(text: "一起散步")),
        DomainEvent(objectID: id, author: author, sequence: 2, lamport: 2, createdAt: date.addingTimeInterval(100), payload: .wishStatus(.fulfilled)),
        DomainEvent(objectID: id, author: author, sequence: 3, lamport: 3, createdAt: date.addingTimeInterval(200), payload: .wishStatus(.active)),
        // A corrected device clock must not override logical version ordering.
        DomainEvent(objectID: id, author: author, sequence: 4, lamport: 4, createdAt: date.addingTimeInterval(50), payload: .wishStatus(.fulfilled))
    ]
    var forward = SharedState(), reverse = SharedState()
    for event in events {
        try forward.apply(event, cycleOwner: nil)
        if event.sequence == 3 { #expect(forward.wishes[id]?.completedAt == nil) }
    }
    for event in events.reversed() { try reverse.apply(event, cycleOwner: nil) }
    #expect(forward == reverse)
    #expect(forward.wishes[id]?.completedAt == date.addingTimeInterval(50))
    let restored = try JSONDecoder().decode(SharedState.self, from: JSONEncoder().encode(reverse))
    #expect(restored == forward)
}

@Test func legacyWishWithoutCompletionDateDecodesWithoutInventingTime() throws {
    let author = UUID(), id = UUID()
    var state = SharedState()
    try state.apply(DomainEvent(objectID: id, author: author, sequence: 1, lamport: 1, createdAt: Date(), payload: .wishCreated(text: "老愿望")), cycleOwner: nil)
    let wish = try #require(state.wishes[id])
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wish)) as? [String: Any])
    json["status"] = "fulfilled"
    json.removeValue(forKey: "completedAt")
    let restored = try JSONDecoder().decode(Wish.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.status == .fulfilled)
    #expect(restored.completedAt == nil)
}

@Test func concurrentWishUpdatesConvergeAcrossArrivalOrders() throws {
    let a = UUID(), b = UUID(), wish = UUID(), date = Date()
    let create = DomainEvent(objectID: wish, author: a, sequence: 1, lamport: 1, createdAt: date, payload: .wishCreated(text: "去巴黎"))
    let fulfilled = DomainEvent(objectID: wish, author: a, sequence: 2, lamport: 2, createdAt: date, payload: .wishStatus(.fulfilled))
    let deferred = DomainEvent(objectID: wish, author: b, sequence: 1, lamport: 2, createdAt: date, payload: .wishStatus(.deferred))
    var left = SharedState(), right = SharedState()
    for event in [create, fulfilled, deferred] { try left.apply(event, cycleOwner: nil) }
    for event in [deferred, fulfilled, create] { try right.apply(event, cycleOwner: nil) }
    #expect(left == right)
}

@Test func cycleRevocationRejectsStaleProjectionAndOtherAuthor() throws {
    let owner = UUID(), other = UUID(), date = Date()
    let shared = SharedCycleProjection(owner: owner, generation: 1, revision: 1, startDate: "2026-09-01")
    let revoked = SharedCycleProjection(owner: owner, generation: 2, revision: 1, startDate: nil, revoked: true)
    var state = SharedState()
    let old = DomainEvent(author: owner, sequence: 1, lamport: 1, createdAt: date, payload: .cycle(shared))
    let new = DomainEvent(author: owner, sequence: 2, lamport: 2, createdAt: date, payload: .cycle(revoked))
    try state.apply(new, cycleOwner: owner); try state.apply(old, cycleOwner: owner)
    #expect(state.cycle == revoked)
    let forged = DomainEvent(author: other, sequence: 1, lamport: 3, createdAt: date, payload: .cycle(shared))
    #expect(throws: SpaceError.unauthorized) { try state.apply(forged, cycleOwner: owner) }
    #expect(throws: SpaceError.invalidInput) {
        try SharedCycleProjection(owner: owner, generation: 1, revision: 1, startDate: "2026-02-31").validate()
    }
}

@Test func reminderSamplingUsesAllowedIntervalsAndDoesNotResample() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let intent = ReminderIntent(wishID: UUID(), receivedAt: now)
    let intervals = [DateInterval(start: now, duration: 100), DateInterval(start: now.addingTimeInterval(1_000), duration: 100)]
    let planner = ReminderPlanner()
    let planned = try planner.plan(intent, allowed: intervals, sample: 0.75)
    #expect(planned.fireAt == now.addingTimeInterval(1_050))
    #expect(try planner.plan(planned, allowed: intervals, sample: 0) == planned)
    #expect(throws: SpaceError.invalidInput) { try planner.plan(intent, allowed: intervals, sample: 1) }
}

@Test func mailboxDoesNotRefreshTTLAndEnforcesTwoMembers() async throws {
    let a = UUID(), b = UUID(), pair = UUID(), now = Date()
    let relay = try LocalMailbox(pairID: pair, members: [a, b], ttl: 10)
    let envelope = Envelope(pairID: pair, epoch: 1, sender: a, recipient: b, ciphertext: Data([1]))
    try await relay.put(envelope, now: now)
    try await relay.put(envelope, now: now.addingTimeInterval(9))
    #expect(try await relay.fetch(recipient: b, now: now.addingTimeInterval(10)).isEmpty)
    let bad = Envelope(pairID: pair, epoch: 1, sender: a, recipient: UUID(), ciphertext: Data([1]))
    do { try await relay.put(bad, now: now); Issue.record("accepted third member") } catch { #expect(error as? SpaceError == .unauthorized) }
}
