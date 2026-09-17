import Foundation
import Domain

public struct Envelope: Codable, Equatable, Sendable {
    public enum AlertKind: String, Codable, Sendable { case message, wish }
    public let wireVersion: Int
    public let pairID: UUID
    public let epoch: UInt64
    public let sender: UUID
    public let recipient: UUID
    public let id: UUID
    public let ciphertext: Data
    /// Generic transient alert routing only; the affection kind stays inside ciphertext.
    public let pushExpiresAt: Double?
    /// Coarse notification category only. The sender, title and content remain encrypted.
    public let alertKind: AlertKind?
    public init(pairID: UUID, epoch: UInt64, sender: UUID, recipient: UUID, id: UUID = UUID(), ciphertext: Data, pushExpiresAt: Double? = nil, alertKind: AlertKind? = nil) {
        self.wireVersion = pushExpiresAt == nil ? 1 : 2; self.pairID = pairID; self.epoch = epoch
        self.sender = sender; self.recipient = recipient; self.id = id; self.ciphertext = ciphertext
        self.pushExpiresAt = pushExpiresAt
        self.alertKind = alertKind
    }
    public func validate() throws {
        guard (wireVersion == 1 && pushExpiresAt == nil) || (wireVersion == 2 && pushExpiresAt?.isFinite == true && pushExpiresAt! > 0) else { throw SpaceError.unsupportedVersion }
        guard wireVersion == 1 || alertKind == nil else { throw SpaceError.invalidEnvelope }
        guard sender != recipient, epoch > 0, !ciphertext.isEmpty, ciphertext.count <= 65_536 else { throw SpaceError.invalidEnvelope }
    }
}
public protocol RelayTransport: Sendable {
    func put(_ envelope: Envelope, now: Date) async throws
    func fetch(recipient: UUID, now: Date) async throws -> [Envelope]
    func acknowledge(recipient: UUID, ids: [UUID]) async throws
}

/// Local deterministic relay for integration tests; never a public network service.
public actor LocalMailbox: RelayTransport {
    private struct Entry { let envelope: Envelope; let expires: Date }
    private var entries: [UUID: Entry] = [:]
    private let pairID: UUID
    private let epoch: UInt64
    private let members: Set<UUID>
    private let ttl: TimeInterval
    private let capacity: Int
    public init(pairID: UUID, epoch: UInt64 = 1, members: Set<UUID>, ttl: TimeInterval = 86_400, capacity: Int = 1_000) throws {
        guard members.count == 2, ttl > 0, capacity > 0 else { throw SpaceError.invalidInput }
        self.pairID = pairID; self.epoch = epoch; self.members = members; self.ttl = ttl; self.capacity = capacity
    }
    public func put(_ envelope: Envelope, now: Date) throws {
        try envelope.validate()
        guard envelope.pairID == pairID, envelope.epoch == epoch,
              members.contains(envelope.sender), members.contains(envelope.recipient) else { throw SpaceError.unauthorized }
        expire(now)
        if let old = entries[envelope.id] {
            guard old.envelope == envelope else { throw SpaceError.conflict }; return
        }
        guard entries.count < capacity else { throw SpaceError.capacity }
        let expires = min(now.addingTimeInterval(ttl), envelope.pushExpiresAt.map { Date(timeIntervalSince1970: $0) } ?? .distantFuture)
        guard expires > now else { throw SpaceError.expired }
        entries[envelope.id] = Entry(envelope: envelope, expires: expires)
    }
    public func fetch(recipient: UUID, now: Date) throws -> [Envelope] {
        guard members.contains(recipient) else { throw SpaceError.unauthorized }
        expire(now)
        return entries.values.filter { $0.envelope.recipient == recipient }.map(\.envelope).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func acknowledge(recipient: UUID, ids: [UUID]) throws {
        guard members.contains(recipient), ids.count <= 100 else { throw SpaceError.unauthorized }
        for id in ids { if let entry = entries[id], entry.envelope.recipient != recipient { throw SpaceError.unauthorized } }
        for id in ids { entries.removeValue(forKey: id) }
    }
    private func expire(_ now: Date) { entries = entries.filter { $0.value.expires > now } }
}
