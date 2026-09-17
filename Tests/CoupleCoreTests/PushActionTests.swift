import Foundation
import Testing
import Domain
import Transport

@Test func notificationReplyRequiresAuthenticatedUnexpiredAffectionAndIsIdempotent() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    try await c.a.sendAffection(.hug, now: now)
    let envelope = try #require(try await c.a.outgoing(now: now).first)
    #expect(envelope.wireVersion == 2)
    #expect(envelope.pushExpiresAt == now.addingTimeInterval(900).timeIntervalSince1970)
    await #expect(throws: SpaceError.expired) { try await c.b.respondToAffection(envelopeID: envelope.id, now: now) }
    try await c.b.receive(envelope, now: now)
    _ = try await c.b.takeAffections(now: now)
    #expect(try await c.b.respondToAffection(envelopeID: envelope.id, now: now))
    #expect(try await !c.b.respondToAffection(envelopeID: envelope.id, now: now.addingTimeInterval(20)))
    #expect(try await c.b.unconfirmedEventCount() == 0)
    #expect(try await c.b.state().messages.isEmpty)
    await #expect(throws: SpaceError.expired) { try await c.b.respondToAffection(envelopeID: envelope.id, now: now.addingTimeInterval(901)) }
}

@Test func pushExpiryTamperingRollsBackDecryptionAndTransientMailboxReallyExpires() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let now = Date()
    try await c.a.sendAffection(.missYou, now: now)
    let original = try #require(try await c.a.outgoing(now: now).first)
    let tampered = Envelope(pairID: original.pairID, epoch: original.epoch, sender: original.sender, recipient: original.recipient,
        id: original.id, ciphertext: original.ciphertext, pushExpiresAt: original.pushExpiresAt! + 100)
    await #expect(throws: SpaceError.invalidEnvelope) { try await c.b.receive(tampered, now: now) }
    try await c.b.receive(original, now: now)
    #expect(try await c.b.takeAffections(now: now).count == 1)
    try await c.relay.put(original, now: now)
    #expect(try await c.relay.fetch(recipient: c.pairB.localID, now: now.addingTimeInterval(901)).isEmpty)
}

@Test func onlyMessageAndNewWishEventsCarryCoarseAlertCategories() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    _ = try await c.a.create(.message(text: "private message"))
    _ = try await c.a.create(.wishCreated(text: "private wish"))
    _ = try await c.a.create(.journal(.anniversary(AnniversaryContent(title: "private date", date: "2027-04-03"))))
    try await c.a.encryptPending()
    let envelopes = try await c.a.outgoing()
    #expect(envelopes.filter { $0.alertKind == .message }.count == 1)
    #expect(envelopes.filter { $0.alertKind == .wish }.count == 1)
    #expect(envelopes.filter { $0.alertKind == nil }.count == 1)
    for envelope in envelopes {
        let wire = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        #expect(!wire.contains("private message"))
        #expect(!wire.contains("private wish"))
        #expect(!wire.contains("private date"))
        try await c.b.receive(envelope)
    }
    #expect(try await c.b.state().messages.count == 1)
    #expect(try await c.b.state().wishes.count == 1)
}
