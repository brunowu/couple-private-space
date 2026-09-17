import Foundation
import CryptoKit
import Domain
import Crypto
import Transport
import Notification

private struct Receipt: Codable { let eventID: UUID; let envelopeID: UUID; let digest: Data }
private enum Body: Codable { case event(DomainEvent); case receipt(Receipt); case affection(Affection) }
private struct Inner: Codable {
    let wireVersion: Int
    let pairID: UUID
    let epoch: UInt64
    let sender: UUID
    let recipient: UUID
    let envelopeID: UUID
    let body: Body
}
private struct Outgoing: Codable {
    let envelope: Envelope; let eventID: UUID?; var delivery: DeliveryState
    var expiresAt: Date?
    var affectionWatermark: UInt64?
}
private struct Received: Codable { let digest: Data; let eventID: UUID?; var expiresAt: Date? }
private struct AffectionAction: Codable { let affection: Affection; var responded: Bool }

public actor SyncCoordinator {
    private let db: any TransactionalStore
    private let cipher: any SessionCipher
    private let pair: PairContext
    private var syncing = false
    public init(db: any TransactionalStore, cipher: any SessionCipher, pair: PairContext) throws {
        self.db = db; self.cipher = cipher; self.pair = pair
        try db.transaction {
            if let old = try db.decode(PairContext.self, table: "app", key: "pair"), old != pair { throw SpaceError.unauthorized }
            try db.encode(pair, table: "app", key: "pair")
        }
    }
    @discardableResult
    public func create(_ payload: EventPayload, objectID: UUID = UUID(), now: Date = Date()) throws -> DomainEvent {
        if case .media = payload { throw SpaceError.invalidInput }
        // Local-first transaction is independent of encryption availability.
        return try db.transaction { try createInTransaction(payload, objectID: objectID, now: now) }
    }
    @discardableResult public func createPhoto(_ jpeg: Data, width: Int, height: Int,
                                               objectID: UUID = UUID(), now: Date = Date()) throws -> DomainEvent {
        let (manifest, sealed) = try preparePhoto(jpeg, width: width, height: height, destination: nil)
        return try db.transaction {
            guard try db.read("mediaBlobs", key: objectID.uuidString) == nil else { throw SpaceError.conflict }
            try db.write("mediaBlobs", key: objectID.uuidString, value: sealed)
            return try createInTransaction(.media(manifest), objectID: objectID, now: now)
        }
    }
    private func preparePhoto(_ jpeg: Data, width: Int, height: Int,
                              destination: MediaDestination?) throws -> (MediaManifest, Data) {
        guard (1...2_000_000).contains(jpeg.count) else { throw SpaceError.capacity }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let manifest = MediaManifest(byteCount: jpeg.count, width: width, height: height,
                                     sha256: Data(SHA256.hash(data: jpeg)), fileKey: keyData,
                                     destination: destination)
        try manifest.validate()
        guard let sealed = try AES.GCM.seal(jpeg, using: key).combined else { throw SpaceError.invalidEnvelope }
        return (manifest, sealed)
    }
    /// Commits the attachment and its owning memory/capsule in one local transaction.
    @discardableResult public func createWithPhoto(_ payload: EventPayload, jpeg: Data,
                                                     width: Int, height: Int, objectID: UUID,
                                                     destination: MediaDestination,
                                                     now: Date = Date()) throws -> DomainEvent {
        switch (payload, destination) {
        case (.journal(.memory(let memory)), .memory) where memory.mediaID == objectID: break
        case (.journal(.sealCapsule(let capsule)), .capsule) where capsule.mediaID == objectID: break
        case (.profile(let profile), .avatar) where profile.avatarID == objectID: break
        default: throw SpaceError.invalidInput
        }
        let (manifest, sealed) = try preparePhoto(jpeg, width: width, height: height,
                                                   destination: destination)
        return try db.transaction {
            guard try db.read("mediaBlobs", key: objectID.uuidString) == nil else { throw SpaceError.conflict }
            try db.write("mediaBlobs", key: objectID.uuidString, value: sealed)
            _ = try createInTransaction(.media(manifest), objectID: objectID, now: now)
            return try createInTransaction(payload, objectID: objectID, now: now)
        }
    }
    public func sealCapsuleDraft(_ draft: CapsuleDraft, now: Date = Date()) throws {
        try draft.validate()
        let payload = EventPayload.journal(.sealCapsule(draft.content))
        if let jpeg = draft.photoJPEG, let width = draft.photoWidth, let height = draft.photoHeight {
            _ = try createWithPhoto(payload, jpeg: jpeg, width: width, height: height,
                                    objectID: draft.id, destination: .capsule, now: now)
        } else {
            _ = try create(payload, objectID: draft.id, now: now)
        }
    }
    public func updateProfile(name: String, avatar: (jpeg: Data, width: Int, height: Int)? = nil,
                              retainedAvatarID: UUID? = nil, now: Date = Date()) throws {
        if let avatar {
            let id = UUID()
            _ = try createWithPhoto(.profile(ProfileContent(name: name, avatarID: id)),
                                    jpeg: avatar.jpeg, width: avatar.width, height: avatar.height,
                                    objectID: id, destination: .avatar, now: now)
        } else {
            if let retainedAvatarID {
                guard let asset = try state().media[retainedAvatarID], asset.author == pair.localID,
                      asset.destination == .avatar else { throw SpaceError.invalidInput }
            }
            _ = try create(.profile(ProfileContent(name: name, avatarID: retainedAvatarID)),
                           objectID: retainedAvatarID ?? UUID(), now: now)
        }
    }
    public func photoCiphertext(_ id: UUID) throws -> Data? {
        guard let asset = try state().media[id], asset.author == pair.localID else { return nil }
        return try db.read("mediaBlobs", key: id.uuidString)
    }
    public func missingPeerPhotoIDs() throws -> [UUID] {
        try state().media.values.compactMap { asset in
            guard asset.author == pair.peerID,
                  try db.read("mediaBlobs", key: asset.id.uuidString) == nil else { return nil }
            return asset.id
        }
    }
    public func photoData(_ id: UUID) throws -> Data? {
        guard let asset = try state().media[id], let sealed = try db.read("mediaBlobs", key: id.uuidString) else { return nil }
        return try verifyPhoto(sealed, manifest: asset.manifest)
    }
    private func verifyPhoto(_ sealed: Data, manifest: MediaManifest) throws -> Data {
        guard sealed.count <= manifest.byteCount + 64 else { throw SpaceError.capacity }
        let box = try AES.GCM.SealedBox(combined: sealed)
        let clear = try AES.GCM.open(box, using: SymmetricKey(data: manifest.fileKey))
        guard clear.count == manifest.byteCount, Data(SHA256.hash(data: clear)) == manifest.sha256 else {
            throw SpaceError.invalidEnvelope
        }
        return clear
    }
    /// Used by a future live peer transport. A metadata receipt is not sent until this commits.
    public func receivePhotoCiphertext(_ sealed: Data, id: UUID) throws {
        guard let asset = try state().media[id], asset.author == pair.peerID else { throw SpaceError.unauthorized }
        _ = try verifyPhoto(sealed, manifest: asset.manifest)
        try db.transaction {
            if let old = try db.read("mediaBlobs", key: id.uuidString) {
                guard old == sealed else { throw SpaceError.conflict }
                return
            }
            try db.write("mediaBlobs", key: id.uuidString, value: sealed)
            for (envelopeID, bytes) in try db.entries("inbox") {
                let received = try JSONDecoder().decode(Received.self, from: bytes)
                guard let eventID = received.eventID,
                      let event = try db.decode(DomainEvent.self, table: "events", key: eventID.uuidString),
                      event.objectID == id, case .media = event.payload,
                      let uuid = UUID(uuidString: envelopeID) else { continue }
                try db.encode(Receipt(eventID: eventID, envelopeID: uuid, digest: received.digest),
                              table: "receiptIntents", key: envelopeID)
            }
        }
    }
    private func createInTransaction(_ payload: EventPayload, objectID: UUID, now: Date) throws -> DomainEvent {
            if case .journal(.sealCapsule(let value)) = payload, let rootID = value.companionOf {
                let journal = try state().journal
                guard let root = journal.capsules[rootID], root.author != pair.localID,
                      root.value.partnerSlotID == objectID, root.value.companionOf == nil,
                      root.value.title == value.title, root.value.opensAt == value.opensAt,
                      !journal.isCancelled(root) else { throw SpaceError.invalidInput }
            }
            let seq = (try db.decode(UInt64.self, table: "app", key: "sequence") ?? 0)
            let clock = (try db.decode(UInt64.self, table: "app", key: "lamport") ?? 0)
            guard seq < UInt64.max - 1, clock < UInt64.max - 1 else { throw SpaceError.capacity }
            let event = DomainEvent(objectID: objectID, author: pair.localID, sequence: seq + 1, lamport: clock + 1, createdAt: now, payload: payload)
            try apply(event, incoming: false, now: now)
            if case .journal(.sealCapsule) = payload { try db.remove("capsuleDrafts", key: objectID.uuidString) }
            try db.encode(seq + 1, table: "app", key: "sequence")
            try db.encode(clock + 1, table: "app", key: "lamport")
            try db.encode(event, table: "pending", key: event.id.uuidString)
            try db.encode(DeliveryState.local, table: "delivery", key: event.id.uuidString)
            return event
    }
    public func privateCycle() throws -> CycleEntry? {
        guard pair.cycleOwner == pair.localID else { return nil }
        return try db.decode(CycleEntry.self, table: "privateCycle", key: "current")
    }
    public func saveCycle(_ entry: CycleEntry, now: Date = Date()) throws {
        guard pair.cycleOwner == pair.localID else { throw SpaceError.unauthorized }
        try entry.validate(today: CivilDate.string(now))
        try db.transaction {
            let old = try state().cycle
            let generation = old?.generation ?? 0
            guard generation < UInt64.max else { throw SpaceError.capacity }
            let projection = entry.projection(owner: pair.localID, generation: generation + 1)
            // Private-only edits need no shared event unless an existing projection must be revoked.
            if !projection.revoked || (old != nil && old?.revoked == false) {
                _ = try createInTransaction(.cycle(projection), objectID: pair.localID, now: now)
            }
            try db.encode(entry, table: "privateCycle", key: "current")
        }
    }
    public func encryptPending() throws {
        for (key, bytes) in try db.entries("pending") {
            let event = try JSONDecoder().decode(DomainEvent.self, from: bytes)
            try db.transaction {
                _ = try enqueue(.event(event), eventID: event.id)
                try db.remove("pending", key: key)
                try db.encode(DeliveryState.encrypted, table: "delivery", key: key)
            }
        }
    }
    public func outgoing(now: Date = Date()) throws -> [Envelope] {
        try db.entries("outbox").compactMap {
            let entry = try JSONDecoder().decode(Outgoing.self, from: $0.1)
            return entry.expiresAt.map({ $0 <= now }) == true ? nil : entry.envelope
        }
    }
    /// Returns false for a coalesced tap. Does not generate a durable business event or unread count.
    @discardableResult public func sendAffection(_ kind: AffectionKind, now: Date = Date()) throws -> Bool {
        try pruneAffections(now: now)
        return try db.transaction {
            try queueAffection(kind, now: now)
        }
    }
    private func queueAffection(_ kind: AffectionKind, now: Date) throws -> Bool {
            if let previous = try db.decode(Date.self, table: "affectionCooldown", key: kind.rawValue),
               now.timeIntervalSince(previous) < 10 { return false }
            let sent = try db.decode(UInt64.self, table: "app", key: "affectionSent") ?? 0
            let acknowledged = try db.decode(UInt64.self, table: "app", key: "affectionAcknowledged") ?? 0
            // Expiring encrypted packets advances Signal's sender chain. Bound unconfirmed
            // gaps so prolonged offline tapping cannot exhaust the peer's skipped-key window.
            guard sent < UInt64.max, sent >= acknowledged, sent - acknowledged < 32 else { throw SpaceError.capacity }
            try db.encode(sent + 1, table: "app", key: "affectionSent")
            let value = Affection(kind: kind, now: now)
            _ = try enqueue(.affection(value), eventID: value.id, expiresAt: value.expiresAt)
            try db.encode(now, table: "affectionCooldown", key: kind.rawValue)
            return true
    }
    /// The push payload alone never authorizes a reply; only a decrypted, unexpired record does.
    public func respondToAffection(envelopeID: UUID, now: Date = Date()) throws -> Bool {
        try pruneAffections(now: now)
        return try db.transaction {
            guard var action = try db.decode(AffectionAction.self, table: "affectionActions", key: envelopeID.uuidString),
                  action.affection.expiresAt > now else { throw SpaceError.expired }
            guard !action.responded else { return false }
            let sent = try queueAffection(action.affection.kind, now: now)
            action.responded = true
            try db.encode(action, table: "affectionActions", key: envelopeID.uuidString)
            return sent
        }
    }
    #if DEBUG
    public func latestAffectionActionID(now: Date = Date()) throws -> UUID? {
        try db.entries("affectionActions").compactMap { key, bytes -> (UUID, Date)? in
            let value = try JSONDecoder().decode(AffectionAction.self, from: bytes)
            guard value.affection.expiresAt > now, !value.responded, let id = UUID(uuidString: key) else { return nil }
            return (id, value.affection.createdAt)
        }.max { $0.1 < $1.1 }?.0
    }
    #endif
    /// Consume before presentation so relaunches cannot replay old animations.
    public func takeAffections(now: Date = Date()) throws -> [Affection] {
        try pruneAffections(now: now)
        return try db.transaction {
            let values = try db.entries("affections").map { try JSONDecoder().decode(Affection.self, from: $0.1) }
            for value in values { try db.remove("affections", key: value.id.uuidString) }
            return values.filter { $0.expiresAt > now }.sorted { $0.createdAt < $1.createdAt }
        }
    }
    private func pruneAffections(now: Date) throws {
        try db.transaction {
            for (key, bytes) in try db.entries("inbox") {
                let value = try JSONDecoder().decode(Received.self, from: bytes)
                if let expiry = value.expiresAt, expiry <= now { try db.remove("inbox", key: key) }
            }
            for (key, bytes) in try db.entries("affectionActions") {
                let value = try JSONDecoder().decode(AffectionAction.self, from: bytes)
                if value.affection.expiresAt <= now { try db.remove("affectionActions", key: key) }
            }
            for (key, bytes) in try db.entries("outbox") {
                let entry = try JSONDecoder().decode(Outgoing.self, from: bytes)
                if let expires = entry.expiresAt, expires <= now { try db.remove("outbox", key: key) }
            }
            for (key, bytes) in try db.entries("affections") {
                let value = try JSONDecoder().decode(Affection.self, from: bytes)
                if value.expiresAt <= now { try db.remove("affections", key: key) }
            }
            for (key, bytes) in try db.entries("affectionCooldown") {
                let value = try JSONDecoder().decode(Date.self, from: bytes)
                if now.timeIntervalSince(value) >= 900 { try db.remove("affectionCooldown", key: key) }
            }
        }
    }
    public func unconfirmedEventCount() throws -> Int {
        try db.entries("pending").count + db.entries("outbox").filter {
            let entry = try JSONDecoder().decode(Outgoing.self, from: $0.1)
            return entry.eventID != nil && entry.expiresAt == nil
        }.count
    }
    public func markUploaded(_ envelopeID: UUID) throws {
        try db.transaction {
            guard var entry = try db.decode(Outgoing.self, table: "outbox", key: envelopeID.uuidString) else { return }
            if let event = entry.eventID {
                entry.delivery = .uploaded
                try db.encode(entry, table: "outbox", key: envelopeID.uuidString)
                if entry.expiresAt == nil { try db.encode(DeliveryState.uploaded, table: "delivery", key: event.uuidString) }
            } else {
                // Control receipts do not require another receipt. Duplicate business delivery repairs a lost receipt.
                try db.remove("outbox", key: envelopeID.uuidString)
            }
        }
    }
    public func receive(_ envelope: Envelope, now: Date = Date()) throws {
        try envelope.validate()
        guard envelope.pairID == pair.pairID, envelope.epoch == pair.epoch,
              envelope.sender == pair.peerID, envelope.recipient == pair.localID else { throw SpaceError.unauthorized }
        let digest = Data(SHA256.hash(data: envelope.ciphertext))
        try db.transaction {
            if let seen = try db.decode(Received.self, table: "inbox", key: envelope.id.uuidString) {
                guard seen.digest == digest else { throw SpaceError.conflict }
                if let eventID = seen.eventID {
                    let event = try db.decode(DomainEvent.self, table: "events", key: eventID.uuidString)
                    let awaitingPhoto = event.map { record in
                        if case .media = record.payload { return true }; return false
                    } ?? false
                    let hasPhoto = try db.read("mediaBlobs", key: event?.objectID.uuidString ?? "") != nil
                    if !awaitingPhoto || hasPhoto {
                        try receiptIntent(eventID: eventID, envelope: envelope, digest: digest)
                    }
                }
                return
            }
            let packet = try JSONDecoder().decode(CipherPacket.self, from: envelope.ciphertext)
            let plaintext = try cipher.decrypt(packet)
            let inner = try JSONDecoder().decode(Inner.self, from: plaintext)
            guard (1...2).contains(inner.wireVersion), inner.pairID == envelope.pairID, inner.epoch == envelope.epoch,
                  inner.sender == envelope.sender, inner.recipient == envelope.recipient,
                  inner.envelopeID == envelope.id else { throw SpaceError.invalidEnvelope }
            let eventID: UUID?
            var dedupeExpiry: Date?
            switch inner.body {
            case .affection(let affection):
                guard inner.wireVersion == 2 else { throw SpaceError.unsupportedVersion }
                try affection.validate(now: now)
                if let expiry = envelope.pushExpiresAt {
                    guard abs(expiry - affection.expiresAt.timeIntervalSince1970) < 0.001 else { throw SpaceError.invalidEnvelope }
                }
                if affection.expiresAt > now {
                    try db.encode(affection, table: "affections", key: affection.id.uuidString)
                    try db.encode(AffectionAction(affection: affection, responded: false), table: "affectionActions", key: envelope.id.uuidString)
                }
                try receiptIntent(eventID: affection.id, envelope: envelope, digest: digest)
                eventID = affection.id
                dedupeExpiry = affection.expiresAt.addingTimeInterval(86_400)
            case .event(let event):
                guard envelope.pushExpiresAt == nil else { throw SpaceError.invalidEnvelope }
                guard event.author == pair.peerID else { throw SpaceError.unauthorized }
                try apply(event, incoming: true, now: now)
                let clock = try db.decode(UInt64.self, table: "app", key: "lamport") ?? 0
                try db.encode(max(clock, event.lamport), table: "app", key: "lamport")
                if case .media = event.payload {
                    // Persisting the manifest does not mean the photo arrived.
                    if try db.read("mediaBlobs", key: event.objectID.uuidString) != nil {
                        try receiptIntent(eventID: event.id, envelope: envelope, digest: digest)
                    }
                } else { try receiptIntent(eventID: event.id, envelope: envelope, digest: digest) }
                eventID = event.id
            case .receipt(let receipt):
                guard envelope.pushExpiresAt == nil else { throw SpaceError.invalidEnvelope }
                if let sent = try db.decode(Outgoing.self, table: "outbox", key: receipt.envelopeID.uuidString) {
                    guard sent.eventID == receipt.eventID,
                          Data(SHA256.hash(data: sent.envelope.ciphertext)) == receipt.digest else { throw SpaceError.invalidEnvelope }
                    if sent.expiresAt == nil { try db.encode(DeliveryState.delivered, table: "delivery", key: receipt.eventID.uuidString) }
                    let acknowledged = try db.decode(UInt64.self, table: "app", key: "affectionAcknowledged") ?? 0
                    try db.encode(max(acknowledged, sent.affectionWatermark ?? 0), table: "app", key: "affectionAcknowledged")
                    try db.remove("outbox", key: receipt.envelopeID.uuidString)
                }
                eventID = nil
            }
            try db.encode(Received(digest: digest, eventID: eventID, expiresAt: dedupeExpiry), table: "inbox", key: envelope.id.uuidString)
        }
    }
    public func encryptReceipts() throws {
        for (key, bytes) in try db.entries("receiptIntents") {
            let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
            try db.transaction {
                _ = try enqueue(.receipt(receipt), eventID: nil)
                try db.remove("receiptIntents", key: key)
            }
        }
    }
    public func sync(using relay: any RelayTransport, now: Date = Date()) async throws {
        guard !syncing else { return }; syncing = true; defer { syncing = false }
        try pruneAffections(now: now); try encryptPending(); try encryptReceipts()
        for envelope in try outgoing(now: now) {
            try Task.checkCancellation()
            try await relay.put(envelope, now: now); try markUploaded(envelope.id)
        }
        for envelope in try await relay.fetch(recipient: pair.localID, now: now) {
            try Task.checkCancellation()
            try receive(envelope, now: now)
            try await relay.acknowledge(recipient: pair.localID, ids: [envelope.id])
        }
        try encryptReceipts()
        // Leave business retransmission to the next run. Flush newly generated control receipts now.
        for (_, bytes) in try db.entries("outbox") {
            let entry = try JSONDecoder().decode(Outgoing.self, from: bytes)
            if entry.eventID == nil, entry.expiresAt.map({ $0 > now }) ?? true {
                try await relay.put(entry.envelope, now: now); try markUploaded(entry.envelope.id)
            }
        }
    }
    public func state() throws -> SharedState { try db.decode(SharedState.self, table: "app", key: "state") ?? SharedState() }
    public func delivery(_ eventID: UUID) throws -> DeliveryState? { try db.decode(DeliveryState.self, table: "delivery", key: eventID.uuidString) }
    public func deliveries() throws -> [UUID: DeliveryState] {
        var result: [UUID: DeliveryState] = [:]
        for (key, bytes) in try db.entries("delivery") {
            if let id = UUID(uuidString: key) { result[id] = try JSONDecoder().decode(DeliveryState.self, from: bytes) }
        }
        return result
    }
    public func capsuleDrafts() throws -> [CapsuleDraft] {
        try db.entries("capsuleDrafts").map { try JSONDecoder().decode(CapsuleDraft.self, from: $0.1) }.sorted { $0.opensAt < $1.opensAt }
    }
    public func saveCapsuleDraft(_ value: CapsuleDraft) throws {
        try value.validate()
        try db.transaction {
            guard try db.read("discardedCapsuleDrafts", key: value.id.uuidString) == nil,
                  try state().journal.capsules[value.id] == nil else { return }
            if let old = try db.decode(CapsuleDraft.self, table: "capsuleDrafts", key: value.id.uuidString),
               old.generation != value.generation || old.revision > value.revision { return }
            try db.encode(value, table: "capsuleDrafts", key: value.id.uuidString)
        }
    }
    public func discardCapsuleDraft(_ id: UUID) throws {
        try db.transaction {
            let revision = try db.decode(CapsuleDraft.self, table: "capsuleDrafts", key: id.uuidString)?.revision ?? 0
            try db.encode(revision, table: "discardedCapsuleDrafts", key: id.uuidString)
            try db.remove("capsuleDrafts", key: id.uuidString)
        }
    }
    /// Explicitly restarting a discarded companion draft preserves its reserved shared object ID.
    public func prepareCapsuleDraft(_ value: CapsuleDraft) throws -> CapsuleDraft {
        try value.validate()
        return try db.transaction {
            if let existing = try db.decode(CapsuleDraft.self, table: "capsuleDrafts", key: value.id.uuidString) { return existing }
            guard try state().journal.capsules[value.id] == nil else { throw SpaceError.conflict }
            var next = value
            if let revision = try db.decode(UInt64.self, table: "discardedCapsuleDrafts", key: value.id.uuidString) {
                guard revision < UInt64.max - 1 else { throw SpaceError.capacity }
                next.revision = max(next.revision, revision + 1)
                try db.remove("discardedCapsuleDrafts", key: value.id.uuidString)
            }
            try db.encode(next, table: "capsuleDrafts", key: value.id.uuidString)
            return next
        }
    }
    public func openedCapsules() throws -> Set<UUID> {
        Set(try db.entries("openedCapsules").compactMap { UUID(uuidString: $0.0) })
    }
    public func openWishReminder(_ id: UUID) throws {
        try db.transaction {
            guard var intent = try db.decode(ReminderIntent.self, table: "reminders", key: id.uuidString) else { return }
            intent.state = .opened
            try db.encode(intent, table: "reminders", key: id.uuidString)
        }
    }
    public func openCapsule(_ id: UUID, now: Date = Date()) throws {
        try db.transaction {
            let journal = try state().journal
            guard let value = journal.capsules[id], journal.canOpen(value, now: now) else { throw SpaceError.unauthorized }
            if try db.read("openedCapsules", key: id.uuidString) == nil { try db.encode(now, table: "openedCapsules", key: id.uuidString) }
        }
    }
    public func reminders() throws -> [ReminderIntent] { try db.entries("reminders").map { try JSONDecoder().decode(ReminderIntent.self, from: $0.1) } }
    public func planReminder(wishID: UUID, allowed: [DateInterval], sample: Double) throws -> ReminderIntent {
        try db.transaction {
            guard let intent = try db.decode(ReminderIntent.self, table: "reminders", key: wishID.uuidString) else { throw SpaceError.missingRecord }
            let planned = try ReminderPlanner().plan(intent, allowed: allowed, sample: sample)
            try db.encode(planned, table: "reminders", key: wishID.uuidString); return planned
        }
    }
    public func resetFutureReminderPlans(now: Date = Date()) throws {
        try db.transaction {
            for var intent in try reminders() where intent.state != .cancelled && intent.state != .opened {
                guard let fireAt = intent.fireAt, fireAt > now else { continue }
                intent.fireAt = nil; intent.state = .needsPlanning
                try db.encode(intent, table: "reminders", key: intent.wishID.uuidString)
            }
        }
    }
    private func enqueue(_ body: Body, eventID: UUID?, expiresAt: Date? = nil) throws -> Envelope {
        let id = UUID()
        let version: Int
        if case .affection = body { version = 2 } else { version = 1 }
        let alertKind: Envelope.AlertKind?
        if case .event(let event) = body {
            switch event.payload {
            case .message: alertKind = .message
            case .wishCreated: alertKind = .wish
            case .media(let manifest) where manifest.destination == .chat: alertKind = .message
            default: alertKind = nil
            }
        } else { alertKind = nil }
        let inner = Inner(wireVersion: version, pairID: pair.pairID, epoch: pair.epoch, sender: pair.localID, recipient: pair.peerID, envelopeID: id, body: body)
        let packet = try cipher.encrypt(JSONEncoder().encode(inner))
        let envelope = Envelope(pairID: pair.pairID, epoch: pair.epoch, sender: pair.localID, recipient: pair.peerID, id: id, ciphertext: try JSONEncoder().encode(packet), pushExpiresAt: expiresAt?.timeIntervalSince1970, alertKind: alertKind)
        try envelope.validate()
        let watermark = try db.decode(UInt64.self, table: "app", key: "affectionSent") ?? 0
        try db.encode(Outgoing(envelope: envelope, eventID: eventID, delivery: .encrypted, expiresAt: expiresAt, affectionWatermark: watermark), table: "outbox", key: id.uuidString)
        return envelope
    }
    private func receiptIntent(eventID: UUID, envelope: Envelope, digest: Data) throws {
        try db.encode(Receipt(eventID: eventID, envelopeID: envelope.id, digest: digest), table: "receiptIntents", key: envelope.id.uuidString)
    }
    private func apply(_ event: DomainEvent, incoming: Bool, now: Date) throws {
        try event.validate(cycleOwner: pair.cycleOwner)
        if let existing = try db.decode(DomainEvent.self, table: "events", key: event.id.uuidString) {
            guard existing == event else { throw SpaceError.conflict }; return
        }
        let seqKey = "\(event.author):\(event.sequence)"
        if let existing = try db.decode(UUID.self, table: "sequences", key: seqKey), existing != event.id { throw SpaceError.conflict }
        var current = try state(); try current.apply(event, cycleOwner: pair.cycleOwner)
        try db.encode(event, table: "events", key: event.id.uuidString)
        try db.encode(event.id, table: "sequences", key: seqKey)
        try db.encode(current, table: "app", key: "state")
        if current.wishes[event.objectID]?.creator == pair.peerID, current.wishes[event.objectID]?.status == .active,
           try db.read("reminders", key: event.objectID.uuidString) == nil {
            try db.encode(ReminderIntent(wishID: event.objectID, receivedAt: now), table: "reminders", key: event.objectID.uuidString)
        }
        if current.wishes[event.objectID]?.creator == pair.peerID, current.wishes[event.objectID]?.status == .active,
           var intent = try db.decode(ReminderIntent.self, table: "reminders", key: event.objectID.uuidString), intent.state == .cancelled {
            intent.state = .needsPlanning; intent.fireAt = nil
            try db.encode(intent, table: "reminders", key: event.objectID.uuidString)
        }
        if current.wishes[event.objectID]?.status != .active,
           var intent = try db.decode(ReminderIntent.self, table: "reminders", key: event.objectID.uuidString) {
            intent.state = .cancelled; try db.encode(intent, table: "reminders", key: event.objectID.uuidString)
        }
    }
}
