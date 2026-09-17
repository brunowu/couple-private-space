import Foundation
import Testing
import Domain
import Crypto
import Persistence
import Sync

@Test func affectionIsEncryptedDeduplicatedAndNeverBecomesChatHistory() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    #expect(try await c.a.sendAffection(.hug, now: now))
    #expect(try await !c.a.sendAffection(.hug, now: now.addingTimeInterval(9)))
    #expect(try await c.a.unconfirmedEventCount() == 0)
    #expect(try c.dbA.entries("events").isEmpty)
    let envelope = try #require(await c.a.outgoing().first)
    try await c.b.receive(envelope, now: now)
    try await c.b.receive(envelope, now: now)
    let signals = try await c.b.takeAffections(now: now)
    #expect(signals.map(\.kind) == [.hug])
    #expect(try await c.b.takeAffections(now: now).isEmpty)
    #expect(try await c.b.state().messages.isEmpty)
    #expect(try c.dbB.entries("events").isEmpty)
    #expect(try c.dbB.entries("affections").isEmpty)
    #expect(try await c.b.reminders().isEmpty)
    // Retransmission after consuming cannot replay the effect.
    try await c.b.receive(envelope, now: now.addingTimeInterval(2))
    #expect(try await c.b.takeAffections(now: now.addingTimeInterval(2)).isEmpty)
}

@Test func expiredAffectionsAreNotReplayedOrResent() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    try await c.a.sendAffection(.missYou, now: now)
    let envelope = try #require(await c.a.outgoing().first)
    try await c.b.receive(envelope, now: now.addingTimeInterval(900))
    #expect(try await c.b.takeAffections(now: now.addingTimeInterval(900)).isEmpty)
    try await c.a.sync(using: c.relay, now: now.addingTimeInterval(901))
    #expect(try await c.a.outgoing().isEmpty)
    #expect(try c.dbA.entries("affectionCooldown").isEmpty)
    #expect(try await c.relay.fetch(recipient: c.pairB.localID, now: now.addingTimeInterval(901)).isEmpty)
}

@Test func affectionReceivedBeforeRestartIsConsumedOnlyOnce() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    try await c.a.sendAffection(.appreciation, now: now)
    try await c.a.sync(using: c.relay, now: now); try await c.b.sync(using: c.relay, now: now)
    try await c.a.sync(using: c.relay, now: now)
    #expect(try await c.a.outgoing().isEmpty)
    let reopened = try EncryptedDatabase(url: c.dbB.url, key: c.keyB)
    let cipher = try SignalSession(db: reopened, vault: c.vaultB, localID: c.pairB.localID, peerID: c.pairB.peerID)
    let restored = try SyncCoordinator(db: reopened, cipher: cipher, pair: c.pairB)
    #expect(try await restored.takeAffections(now: now).count == 1)
    #expect(try await restored.takeAffections(now: now).isEmpty)
}

@Test func offlineAffectionBudgetProtectsLaterBusinessMessages() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    for index in 0..<32 { try await c.a.sendAffection(.hug, now: now.addingTimeInterval(Double(index) * 11)) }
    await #expect(throws: SpaceError.capacity) { try await c.a.sendAffection(.hug, now: now.addingTimeInterval(1_000)) }
    let later = now.addingTimeInterval(2_000)
    let message = try await c.a.create(.message(text: "之后的消息仍能解密"), now: later)
    try await c.a.sync(using: c.relay, now: later); try await c.b.sync(using: c.relay, now: later); try await c.a.sync(using: c.relay, now: later)
    #expect(try await c.a.delivery(message.id) == .delivered)
    #expect(try await c.a.sendAffection(.hug, now: later))
}
