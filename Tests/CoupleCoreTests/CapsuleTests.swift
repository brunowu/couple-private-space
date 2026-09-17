import Foundation
import Testing
import Domain
import Crypto
import Persistence
import Sync
import Notification

@Test func duetConvergesOutOfOrderAndCancellationOnlyRemovesOwnContribution() throws {
    let a = UUID(), b = UUID(), root = UUID(), slot = UUID(), now = Date(timeIntervalSince1970: 1000)
    let end = now.addingTimeInterval(100)
    let first = DomainEvent(objectID: root, author: a, sequence: 1, lamport: 1, createdAt: now,
        payload: .journal(.sealCapsule(CapsuleContent(title: "未来", text: "我的", opensAt: end, partnerSlotID: slot))))
    let second = DomainEvent(objectID: slot, author: b, sequence: 1, lamport: 2, createdAt: now,
        payload: .journal(.sealCapsule(CapsuleContent(title: "未来", text: "你的", opensAt: end, companionOf: root))))
    var left = SharedState(), right = SharedState()
    try right.apply(second, cycleOwner: nil)
    #expect(!right.journal.canOpen(try #require(right.journal.capsules[slot]), now: end))
    try right.apply(first, cycleOwner: nil)
    for e in [first, second] { try left.apply(e, cycleOwner: nil) }
    #expect(left == right)
    #expect(left.journal.contributions(to: root).count == 2)
    #expect(left.journal.contributions(to: root).allSatisfy { left.journal.canOpen($0, now: end) })
    let plans = CapsuleReminder.eligible(journal: left.journal, opened: [])
    #expect(plans.count == 1)
    #expect(plans.first?.rootID == root)
    #expect(CapsuleReminder.eligible(journal: left.journal, opened: [root, slot]).isEmpty)
    let cancel = DomainEvent(objectID: root, author: a, sequence: 2, lamport: 3, createdAt: now.addingTimeInterval(10), payload: .journal(.cancelCapsule))
    try left.apply(cancel, cycleOwner: nil)
    #expect(!left.journal.canOpen(try #require(left.journal.capsules[root]), now: end))
    #expect(left.journal.canOpen(try #require(left.journal.capsules[slot]), now: end))
    #expect(CapsuleReminder.eligible(journal: left.journal, opened: []).count == 1)
    #expect(CapsuleReminder.eligible(journal: left.journal, opened: [slot]).isEmpty)
}

@Test func mismatchedDuetContributionCannotBeOpened() throws {
    let a = UUID(), root = UUID(), slot = UUID(), now = Date(), end = now.addingTimeInterval(100)
    for invalid in 0..<3 {
        var state = SharedState()
        try state.apply(DomainEvent(objectID: root, author: a, sequence: 1, lamport: 1, createdAt: now,
            payload: .journal(.sealCapsule(CapsuleContent(title: "未来", text: "我的", opensAt: end, partnerSlotID: slot)))), cycleOwner: nil)
        let id = invalid == 0 ? UUID() : slot
        try state.apply(DomainEvent(objectID: id, author: invalid == 1 ? a : UUID(), sequence: 2, lamport: 2, createdAt: now,
            payload: .journal(.sealCapsule(CapsuleContent(title: invalid == 2 ? "被改名" : "未来", text: "无效", opensAt: end, companionOf: root)))), cycleOwner: nil)
        #expect(!state.journal.canOpen(try #require(state.journal.capsules[id]), now: end))
        #expect(state.journal.contributions(to: root).count == 1)
    }
}

@Test func capsuleDraftsArePrivateDurableAndCannotResurrectAfterSealingOrDiscard() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    var draft = CapsuleDraft(title: "明天", text: "私人草稿")
    try await c.a.saveCapsuleDraft(draft)
    let old = draft; draft.text = "较新的草稿"; draft.revision = 1
    try await c.a.saveCapsuleDraft(draft); try await c.a.saveCapsuleDraft(old)
    #expect(try await c.a.capsuleDrafts() == [draft])
    #expect(try await c.a.unconfirmedEventCount() == 0)
    let db = try EncryptedDatabase(url: c.dbA.url, key: c.keyA)
    let cipher = try SignalSession(db: db, vault: c.vaultA, localID: c.pairA.localID, peerID: c.pairA.peerID)
    let reopened = try SyncCoordinator(db: db, cipher: cipher, pair: c.pairA)
    #expect(try await reopened.capsuleDrafts() == [draft])
    try await reopened.create(.journal(.sealCapsule(draft.content)), objectID: draft.id)
    try await reopened.saveCapsuleDraft(draft)
    #expect(try await reopened.capsuleDrafts().isEmpty)
    let discarded = CapsuleDraft(text: "不会再出现")
    try await reopened.discardCapsuleDraft(discarded.id); try await reopened.saveCapsuleDraft(discarded)
    #expect(try await reopened.capsuleDrafts().isEmpty)
    let restarted = try await reopened.prepareCapsuleDraft(CapsuleDraft(id: discarded.id, text: "重新开始"))
    var delayed = discarded; delayed.revision = 100
    try await reopened.saveCapsuleDraft(delayed)
    #expect(try await reopened.capsuleDrafts() == [restarted])
    try await reopened.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.capsuleDrafts().isEmpty)
}

@Test func openedStateRequiresDueValidCapsuleAndStaysLocalAcrossRestart() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date(), end = now.addingTimeInterval(100), id = UUID()
    try await c.a.create(.journal(.sealCapsule(CapsuleContent(title: "以后", text: "你好", opensAt: end))), objectID: id, now: now)
    await #expect(throws: SpaceError.unauthorized) { try await c.a.openCapsule(id, now: now) }
    try await c.a.openCapsule(id, now: end)
    #expect(try await c.a.unconfirmedEventCount() == 1)
    let db = try EncryptedDatabase(url: c.dbA.url, key: c.keyA)
    let cipher = try SignalSession(db: db, vault: c.vaultA, localID: c.pairA.localID, peerID: c.pairA.peerID)
    let reopened = try SyncCoordinator(db: db, cipher: cipher, pair: c.pairA)
    #expect(try await reopened.openedCapsules() == [id])
    await #expect(throws: SpaceError.unauthorized) { try await reopened.openCapsule(id, now: now) }
    try await reopened.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.openedCapsules().isEmpty)
}

@Test func wishReactivationReplansOnlyOnReceiverAndOpenedReminderNeverReplays() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    try await c.a.create(.message(text: "建立接收会话"))
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    let event = try await c.b.create(.wishCreated(text: "一起散步"))
    try await c.b.sync(using: c.relay); try await c.a.sync(using: c.relay)
    let first = try #require(try await c.a.reminders().first)
    #expect(try await c.b.reminders().isEmpty)
    try await c.a.create(.wishStatus(.deferred), objectID: event.objectID)
    #expect(try await c.a.reminders().first?.state == .cancelled)
    try await c.a.create(.wishStatus(.active), objectID: event.objectID)
    #expect(try await c.a.reminders().first?.state == .needsPlanning)
    #expect(try await c.a.reminders().first?.requestID == first.requestID)
    let start = Date().addingTimeInterval(60)
    _ = try await c.a.planReminder(wishID: event.objectID, allowed: [DateInterval(start: start, duration: 3600)], sample: 0.5)
    try await c.a.openWishReminder(event.objectID)
    try await c.a.resetFutureReminderPlans()
    #expect(try await c.a.reminders().first?.state == .opened)
}
