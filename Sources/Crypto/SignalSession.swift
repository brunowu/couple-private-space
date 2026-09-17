import Foundation
import LibSignalClient
import Domain

private struct Context: StoreContext {}

/// All store callbacks read fresh serialized records and write inside the caller's DB transaction.
/// No mutable native session cache survives a rollback.
private final class SignalStore: IdentityKeyStore, SessionStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore {
    let db: any TransactionalStore
    let identity: IdentityKeyPair
    init(db: any TransactionalStore, identity: IdentityKeyPair) { self.db = db; self.identity = identity }
    private func addressKey(_ address: ProtocolAddress) -> String { "\(address.name):\(address.deviceId)" }
    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identity }
    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        guard let id = try db.decode(UInt32.self, table: "crypto", key: "registration") else { throw SpaceError.missingRecord }; return id
    }
    func saveIdentity(_ value: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        guard try isTrustedIdentity(value, for: address, direction: .sending, context: context) else { throw SpaceError.unauthorized }
        return .newOrUnchanged
    }
    func isTrustedIdentity(_ value: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        try db.read("trusted", key: addressKey(address)) == value.serialize()
    }
    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try db.read("trusted", key: addressKey(address)).map { try IdentityKey(bytes: $0) }
    }
    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try db.read("sessions", key: addressKey(address)).map { try SessionRecord(bytes: $0) }
    }
    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { guard let record = try loadSession(for: $0, context: context) else { throw SpaceError.missingRecord }; return record }
    }
    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try db.write("sessions", key: addressKey(address), value: record.serialize())
    }
    private func required(_ table: String, _ id: UInt32) throws -> Data {
        guard let data = try db.read(table, key: String(id)) else { throw SpaceError.missingRecord }; return data
    }
    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord { try PreKeyRecord(bytes: required("prekeys", id)) }
    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws { try db.write("prekeys", key: String(id), value: record.serialize()) }
    func removePreKey(id: UInt32, context: StoreContext) throws { try db.remove("prekeys", key: String(id)) }
    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord { try SignedPreKeyRecord(bytes: required("signedPrekeys", id)) }
    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws { try db.write("signedPrekeys", key: String(id), value: record.serialize()) }
    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord { try KyberPreKeyRecord(bytes: required("kyberPrekeys", id)) }
    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws { try db.write("kyberPrekeys", key: String(id), value: record.serialize()) }
    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        // One invitation / one recipient. Consume the one-time KEM prekey transactionally.
        try db.remove("kyberPrekeys", key: String(id))
    }
}

public struct PublicBundle: Codable, Sendable {
    public let identity: Data
    public let registration: UInt32
    public let prekey: Data
    public let signedPrekey: Data
    public let signedSignature: Data
    public let kyberPrekey: Data
    public let kyberSignature: Data
}

public struct CipherPacket: Codable, Equatable, Sendable {
    public let type: UInt8
    public let bytes: Data
    public init(type: UInt8, bytes: Data) { self.type = type; self.bytes = bytes }
}
public protocol SessionCipher: AnyObject {
    func encrypt(_ plaintext: Data) throws -> CipherPacket
    func decrypt(_ packet: CipherPacket) throws -> Data
}

/// Mature protocol implementation only. Caller owns the atomic transaction.
public final class SignalSession: SessionCipher {
    private let store: SignalStore
    private let local: ProtocolAddress
    private let peer: ProtocolAddress
    public init(db: any TransactionalStore, vault: any KeyVault, localID: UUID, peerID: UUID) throws {
        let name = "identity.\(localID.uuidString)"
        let bytes: Data
        if let existing = try vault.load(name) { bytes = existing }
        else {
            // Do not silently generate a different identity for an existing database.
            guard try db.read("crypto", key: "registration") == nil else { throw SpaceError.missingRecord }
            bytes = IdentityKeyPair.generate().serialize(); try vault.save(bytes, name: name)
        }
        let identity = try IdentityKeyPair(bytes: bytes)
        self.store = SignalStore(db: db, identity: identity)
        self.local = try ProtocolAddress(name: localID.uuidString, deviceId: 1)
        self.peer = try ProtocolAddress(name: peerID.uuidString, deviceId: 1)
        if try db.read("crypto", key: "registration") == nil {
            try db.transaction {
                try db.encode(UInt32.random(in: 1...16_380), table: "crypto", key: "registration")
            }
        }
    }
    public var publicIdentity: Data { store.identity.identityKey.serialize() }
    public func pinnedPeerIdentity() throws -> Data? {
        try store.db.read("trusted", key: "\(peer.name):\(peer.deviceId)")
    }
    public func createBundle() throws -> PublicBundle {
        if let existing = try store.db.decode(PublicBundle.self, table: "crypto", key: "bundle") { return existing }
        return try store.db.transaction {
            let pre = PrivateKey.generate(), signed = PrivateKey.generate(), kem = KEMKeyPair.generate()
            let signature = store.identity.privateKey.generateSignature(message: signed.publicKey.serialize())
            let kemSignature = store.identity.privateKey.generateSignature(message: kem.publicKey.serialize())
            let ctx = Context()
            try store.storePreKey(PreKeyRecord(id: 1, privateKey: pre), id: 1, context: ctx)
            try store.storeSignedPreKey(SignedPreKeyRecord(id: 1, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), privateKey: signed, signature: signature), id: 1, context: ctx)
            try store.storeKyberPreKey(KyberPreKeyRecord(id: 1, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), keyPair: kem, signature: kemSignature), id: 1, context: ctx)
            let bundle = PublicBundle(identity: publicIdentity, registration: try store.localRegistrationId(context: ctx), prekey: pre.publicKey.serialize(), signedPrekey: signed.publicKey.serialize(), signedSignature: signature, kyberPrekey: kem.publicKey.serialize(), kyberSignature: kemSignature)
            try store.db.encode(bundle, table: "crypto", key: "bundle")
            return bundle
        }
    }
    /// Only invoke with identity material authenticated out of band (e.g. mutual QR scan).
    public func pinVerifiedIdentity(_ identity: Data) throws {
        _ = try IdentityKey(bytes: identity)
        try store.db.transaction {
            let key = "\(peer.name):\(peer.deviceId)"
            if let old = try store.db.read("trusted", key: key), old != identity { throw SpaceError.unauthorized }
            try store.db.write("trusted", key: key, value: identity)
        }
    }
    public func establish(with bundle: PublicBundle) throws {
        guard try store.isTrustedIdentity(IdentityKey(bytes: bundle.identity), for: peer, direction: .sending, context: Context()) else { throw SpaceError.unauthorized }
        try store.db.transaction {
            guard try store.loadSession(for: peer, context: Context()) == nil else { throw SpaceError.conflict }
            let native = try PreKeyBundle(registrationId: bundle.registration, deviceId: 1, prekeyId: 1,
                prekey: PublicKey(bundle.prekey), signedPrekeyId: 1, signedPrekey: PublicKey(bundle.signedPrekey),
                signedPrekeySignature: bundle.signedSignature, identity: IdentityKey(bytes: bundle.identity),
                kyberPrekeyId: 1, kyberPrekey: KEMPublicKey(bundle.kyberPrekey), kyberPrekeySignature: bundle.kyberSignature)
            try processPreKeyBundle(native, for: peer, ourAddress: local, sessionStore: store, identityStore: store, context: Context())
        }
    }
    public func encrypt(_ plaintext: Data) throws -> CipherPacket {
        let message = try signalEncrypt(message: plaintext, for: peer, localAddress: local, sessionStore: store, identityStore: store, context: Context())
        return CipherPacket(type: message.messageType.rawValue, bytes: message.serialize())
    }
    public func decrypt(_ packet: CipherPacket) throws -> Data {
        switch packet.type {
        case CiphertextMessage.MessageType.preKey.rawValue:
            return try signalDecryptPreKey(message: PreKeySignalMessage(bytes: packet.bytes), from: peer, localAddress: local, sessionStore: store, identityStore: store, preKeyStore: store, signedPreKeyStore: store, kyberPreKeyStore: store, context: Context())
        case CiphertextMessage.MessageType.whisper.rawValue:
            return try signalDecrypt(message: SignalMessage(bytes: packet.bytes), from: peer, to: local, sessionStore: store, identityStore: store, context: Context())
        default: throw SpaceError.unsupportedVersion
        }
    }
}
