import Foundation
import Testing
import Domain
import Crypto
import Persistence
import Transport
import Sync

final class TestVault: KeyVault {
    var values: [String: Data] = [:]
    func load(_ name: String) throws -> Data? { values[name] }
    func save(_ value: Data, name: String) throws { values[name] = value }
}

struct Clients {
    let dir: URL
    let keyA: Data, keyB: Data
    let vaultA: TestVault, vaultB: TestVault
    let dbA: EncryptedDatabase, dbB: EncryptedDatabase
    let cryptoA: SignalSession, cryptoB: SignalSession
    let a: SyncCoordinator, b: SyncCoordinator
    let pairA: PairContext, pairB: PairContext
    let relay: LocalMailbox
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("couple-tests-\(UUID())")
        keyA = try secureRandomKey(); keyB = try secureRandomKey()
        vaultA = TestVault(); vaultB = TestVault()
        let aid = UUID(), bid = UUID(), pair = UUID()
        pairA = try PairContext(pairID: pair, localID: aid, peerID: bid, cycleOwner: bid)
        pairB = try PairContext(pairID: pair, localID: bid, peerID: aid, cycleOwner: bid)
        dbA = try EncryptedDatabase(url: dir.appendingPathComponent("A/private.sqlite"), key: keyA)
        dbB = try EncryptedDatabase(url: dir.appendingPathComponent("B/private.sqlite"), key: keyB)
        cryptoA = try SignalSession(db: dbA, vault: vaultA, localID: aid, peerID: bid)
        cryptoB = try SignalSession(db: dbB, vault: vaultB, localID: bid, peerID: aid)
        let bundleB = try cryptoB.createBundle()
        try cryptoA.pinVerifiedIdentity(cryptoB.publicIdentity)
        try cryptoB.pinVerifiedIdentity(cryptoA.publicIdentity)
        try cryptoA.establish(with: bundleB)
        a = try SyncCoordinator(db: dbA, cipher: cryptoA, pair: pairA)
        b = try SyncCoordinator(db: dbB, cipher: cryptoB, pair: pairB)
        relay = try LocalMailbox(pairID: pair, members: [aid, bid])
    }
}

@Test func journalEntriesPersistAndSynchronizeWithRealEncryptedReceipts() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let list = try await c.a.create(.journal(.checklist(ChecklistContent(text: "一起吃早餐", category: .eat))))
    let capsule = try await c.a.create(.journal(.sealCapsule(CapsuleContent(title: "给明天", text: "记得拥抱", opensAt: Date().addingTimeInterval(86_400)))))
    let memory = try await c.a.create(.journal(.memory(MemoryContent(title: "今天", text: "很平凡，也很好", date: Date()))))
    // No network yet: all three survive a new coordinator reading the same encrypted store.
    let reopened = try EncryptedDatabase(url: c.dbA.url, key: c.keyA)
    let cipher = try SignalSession(db: reopened, vault: c.vaultA, localID: c.pairA.localID, peerID: c.pairA.peerID)
    let restored = try SyncCoordinator(db: reopened, cipher: cipher, pair: c.pairA)
    #expect(try await restored.state().journal.capsules.count == 1)
    try await restored.sync(using: c.relay); try await c.b.sync(using: c.relay); try await restored.sync(using: c.relay)
    #expect(try await restored.state() == c.b.state())
    for event in [list, capsule, memory] { #expect(try await restored.delivery(event.id) == .delivered) }
    _ = try await c.b.create(.journal(.checklist(ChecklistContent(text: "一起吃早餐", category: .eat, completed: true))), objectID: list.objectID)
    try await c.b.sync(using: c.relay); try await restored.sync(using: c.relay)
    #expect(try await restored.state().journal.checklist[list.objectID]?.value.completed == true)
    _ = try await restored.create(.journal(.cancelCapsule), objectID: capsule.objectID)
    try await restored.sync(using: c.relay); try await c.b.sync(using: c.relay)
    let peer = try await c.b.state()
    #expect(peer.journal.isCancelled(try #require(peer.journal.capsules[capsule.objectID])))
}

@Test func realSignalDeliveryRequiresPersistedEncryptedReceipt() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let event = try await c.a.create(.wishCreated(text: "这个周末一起吃饭"))
    try await c.a.sync(using: c.relay)
    #expect(try await c.a.delivery(event.id) == .uploaded)
    #expect(try await c.b.state().wishes.isEmpty)
    try await c.b.sync(using: c.relay)
    #expect(try await c.b.state().wishes[event.objectID]?.text == "这个周末一起吃饭")
    #expect(try await c.b.reminders().count == 1)
    #expect(try await c.a.delivery(event.id) == .uploaded)
    try await c.a.sync(using: c.relay)
    #expect(try await c.a.delivery(event.id) == .delivered)
    let reply = try await c.b.create(.message(text: "好呀"))
    try await c.b.sync(using: c.relay); try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.delivery(reply.id) == .delivered)
    #expect(try await c.a.state().messages[reply.objectID]?.text == "好呀")
}

@Test func structuredReplyKeepsItsOriginalMessageLinkAcrossSync() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let original = try await c.a.create(.message(text: "今晚吃什么？"))
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    let reply = try await c.b.create(.messageV2(MessageContent(text: "吃火锅", replyTo: original.objectID)))
    try await c.b.sync(using: c.relay); try await c.a.sync(using: c.relay)
    let received = try #require(try await c.a.state().messages[reply.objectID])
    #expect(received.text == "吃火锅")
    #expect(received.replyTo == original.objectID)
}

@Test func chatReactionsCanBeChangedAndRemovedWithoutCreatingMessages() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let message = try await c.a.create(.message(text: "到家啦"))
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    _ = try await c.a.create(.chatReaction(ChatReactionContent(targetID: message.objectID, reaction: .heart)),
                             objectID: message.objectID)
    _ = try await c.b.create(.chatReaction(ChatReactionContent(targetID: message.objectID, reaction: .hug)),
                             objectID: message.objectID)
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.a.state().chatReactions[message.objectID]?[c.pairA.localID]?.reaction == .heart)
    #expect(try await c.a.state().chatReactions[message.objectID]?[c.pairB.localID]?.reaction == .hug)
    _ = try await c.a.create(.chatReaction(ChatReactionContent(targetID: message.objectID, reaction: nil)),
                             objectID: message.objectID)
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.state().chatReactions[message.objectID]?[c.pairA.localID]?.reaction == nil)
    #expect(try await c.b.state().messages.count == 1)
}

@Test func changingReminderWindowKeepsIdentityAndNeverReplaysElapsedReminders() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    let first = try await c.a.create(.wishCreated(text: "future"))
    let second = try await c.a.create(.wishCreated(text: "past"))
    try await c.a.sync(using: c.relay, now: now); try await c.b.sync(using: c.relay, now: now)
    let future = try await c.b.planReminder(wishID: first.objectID, allowed: [DateInterval(start: now, duration: 1_000)], sample: 0.8)
    let elapsed = try await c.b.planReminder(wishID: second.objectID, allowed: [DateInterval(start: now, duration: 10)], sample: 0.5)
    try await c.b.resetFutureReminderPlans(now: now.addingTimeInterval(20))
    let values = try await c.b.reminders()
    #expect(values.first(where: { $0.wishID == first.objectID })?.requestID == future.requestID)
    #expect(values.first(where: { $0.wishID == first.objectID })?.fireAt == nil)
    #expect(values.first(where: { $0.wishID == second.objectID }) == elapsed)
    let completion = try await c.b.create(.wishStatus(.fulfilled), objectID: first.objectID, now: now)
    #expect(try await c.b.reminders().first(where: { $0.wishID == first.objectID })?.state == .cancelled)
    try await c.b.sync(using: c.relay, now: now.addingTimeInterval(100))
    try await c.a.sync(using: c.relay, now: now.addingTimeInterval(200))
    #expect(try await c.a.state().wishes[first.objectID]?.completedAt == completion.createdAt)
    let wishA = try await c.a.state().wishes[first.objectID]
    let wishB = try await c.b.state().wishes[first.objectID]
    #expect(wishA == wishB)
}

@Test func sendCommitFailurePreservesRatchetAndPendingEvent() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    _ = try await c.a.create(.message(text: "保存失败后仍可重试"))
    let before = try c.dbA.entries("sessions").map(\.1)
    c.dbA.failNextCommit = true
    do { try await c.a.encryptPending(); Issue.record("expected injected failure") }
    catch { #expect(error as? SpaceError == .injectedFailure) }
    #expect(try c.dbA.entries("sessions").map(\.1) == before)
    #expect(try await c.a.outgoing().isEmpty)
    try await c.a.encryptPending()
    let original = try await c.a.outgoing()
    try await c.a.encryptPending()
    #expect(try await c.a.outgoing() == original)
    try await c.b.receive(original[0])
    #expect(try await c.b.state().messages.count == 1)
}

@Test func receiveRollbackAndDuplicateDoNotLoseMessageOrRepeatWish() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    _ = try await c.a.create(.wishCreated(text: "一起散步")); try await c.a.encryptPending()
    let envelope = try await c.a.outgoing()[0]
    c.dbB.failNextCommit = true
    do { try await c.b.receive(envelope); Issue.record("expected failure") } catch { #expect(error as? SpaceError == .injectedFailure) }
    #expect(try await c.b.state().wishes.isEmpty)
    #expect(try c.dbB.entries("inbox").isEmpty)
    try await c.b.receive(envelope)
    try await c.b.receive(envelope)
    #expect(try await c.b.state().wishes.count == 1)
    #expect(try await c.b.reminders().count == 1)
}

@Test func lostReceiptAndMailboxExpiryRecoverThroughSameCiphertext() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    let event = try await c.a.create(.message(text: "离线也不会消失"), now: now)
    try await c.a.sync(using: c.relay, now: now)
    let original = try await c.a.outgoing()[0]
    #expect(try await c.relay.fetch(recipient: c.pairB.localID, now: now.addingTimeInterval(86_401)).isEmpty)
    try await c.a.sync(using: c.relay, now: now.addingTimeInterval(86_402))
    #expect(try await c.a.outgoing()[0] == original)
    try await c.b.sync(using: c.relay, now: now.addingTimeInterval(86_403))
    let receipts = try await c.relay.fetch(recipient: c.pairA.localID, now: now.addingTimeInterval(86_404))
    try await c.relay.acknowledge(recipient: c.pairA.localID, ids: receipts.map(\.id)) // simulate lost receipt
    try await c.a.sync(using: c.relay, now: now.addingTimeInterval(86_405))
    try await c.b.sync(using: c.relay, now: now.addingTimeInterval(86_406))
    try await c.a.sync(using: c.relay, now: now.addingTimeInterval(86_407))
    #expect(try await c.a.delivery(event.id) == .delivered)
    #expect(try await c.b.state().messages.count == 1)
}

@Test func tamperingAndWrongRouteAreRejectedWithoutConsumingKeys() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    _ = try await c.a.create(.message(text: "only us")); try await c.a.encryptPending()
    let good = try await c.a.outgoing()[0]
    let wrongRoute = Envelope(pairID: UUID(), epoch: good.epoch, sender: good.sender, recipient: good.recipient, id: good.id, ciphertext: good.ciphertext)
    do { try await c.b.receive(wrongRoute); Issue.record("accepted wrong pair") } catch {}
    var packet = try JSONDecoder().decode(CipherPacket.self, from: good.ciphertext)
    var bytes = packet.bytes; bytes[bytes.count - 1] ^= 1
    packet = CipherPacket(type: packet.type, bytes: bytes)
    let corrupt = Envelope(pairID: good.pairID, epoch: good.epoch, sender: good.sender, recipient: good.recipient, id: good.id, ciphertext: try JSONEncoder().encode(packet))
    do { try await c.b.receive(corrupt); Issue.record("accepted tampering") } catch {}
    try await c.b.receive(good)
    #expect(try await c.b.state().messages.count == 1)
}

@Test func sessionsAndDedupeSurviveReopeningDatabase() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    _ = try await c.a.create(.wishCreated(text: "明年看海")); try await c.a.encryptPending()
    let envelope = try await c.a.outgoing()[0]
    try await c.b.receive(envelope)
    let reopened = try EncryptedDatabase(url: c.dbB.url, key: c.keyB)
    let cipher = try SignalSession(db: reopened, vault: c.vaultB, localID: c.pairB.localID, peerID: c.pairB.peerID)
    let b = try SyncCoordinator(db: reopened, cipher: cipher, pair: c.pairB)
    try await b.receive(envelope)
    #expect(try await b.reminders().count == 1)
    try await b.encryptReceipts()
    for receipt in try await b.outgoing() { try await c.a.receive(receipt) }
    #expect(try await c.a.outgoing().isEmpty)
}
