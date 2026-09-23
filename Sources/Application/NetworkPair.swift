import Foundation
import CryptoKit
import Crypto
import Domain
import Persistence
import Transport
import Sync
import Notification

private struct AuthPublic: Codable, Equatable {
    let kty: String
    let crv: String
    let x: String
    let y: String
    let ext: Bool
    init(_ key: P256.Signing.PrivateKey) {
        let bytes = key.publicKey.x963Representation
        func url64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        kty = "EC"; crv = "P-256"; ext = true
        x = url64(bytes.subdata(in: 1..<33)); y = url64(bytes.subdata(in: 33..<65))
    }
}
private struct PairDevice: Codable, Equatable {
    let deviceID: UUID
    let identityPublic: String
    let authPublicJwk: AuthPublic
}
private struct PairInvite: Codable {
    let version: Int
    let endpoint: URL
    let context: PairContext
    let device: PairDevice
    let bundle: PublicBundle
    let invitation: String
    let expires: Double
}
private struct PairResponse: Codable {
    let version: Int
    let invitationDigest: Data
    let device: PairDevice
    let packet: CipherPacket
}
private struct PairFinal: Codable { let version: Int; let invitationDigest: Data; let packet: CipherPacket }
private struct Confirmation: Codable, Equatable {
    let purpose: String
    let invitationDigest: Data
    let responder: PairDevice
}
private struct PairSetup: Codable {
    var context: PairContext
    var endpoint: URL
    var creator: Bool
    var stage: String
    var invitation: String?
    var response: String?
    var final: String?
}

public enum PairingVerification {
    /// Both phones derive the same 64-bit display code from their Signal identities and this space.
    public static func code(pairID: UUID, first: Data, second: Data) -> String {
        let ordered = [first, second].sorted { $0.lexicographicallyPrecedes($1) }
        var material = Data("CouplePrivateSpace pairing code v1\0\(pairID.uuidString)\0".utf8)
        for identity in ordered { material.append(identity); material.append(0) }
        let digits = Data(SHA256.hash(data: material)).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: digits.count, by: 4).map {
            let start = digits.index(digits.startIndex, offsetBy: $0)
            return String(digits[start..<digits.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

/// Independent, persistent network client. Only public pairing payloads are exported.
public actor NetworkPair {
    private let db: EncryptedDatabase
    private let vault: any KeyVault
    private var setup: PairSetup?
    private var cipher: SignalSession?
    private var relay: HTTPRelay?
    private var coordinator: SyncCoordinator?
    private var mediaSocket: URLSessionWebSocketTask?
    private var busy = false
    public init(directory: URL, vault: any KeyVault) throws {
        self.vault = vault
        let key: Data
        if let saved = try vault.load("network.database") { key = saved }
        else { key = try secureRandomKey(); try vault.save(key, name: "network.database") }
        db = try EncryptedDatabase(url: directory.appendingPathComponent("network.sqlite"), key: key)
        setup = try db.decode(PairSetup.self, table: "network", key: "setup")
    }
    private func authKey() throws -> P256.Signing.PrivateKey {
        if let data = try vault.load("network.auth") { return try P256.Signing.PrivateKey(rawRepresentation: data) }
        let key = P256.Signing.PrivateKey(); try vault.save(key.rawRepresentation, name: "network.auth"); return key
    }
    private func save(_ value: PairSetup) throws {
        try db.transaction { try db.encode(value, table: "network", key: "setup") }; setup = value
    }
    private func connect() throws {
        guard let setup else { throw SpaceError.missingRecord }
        if cipher == nil { cipher = try SignalSession(db: db, vault: vault, localID: setup.context.localID, peerID: setup.context.peerID) }
        if relay == nil { relay = try HTTPRelay(baseURL: setup.endpoint, deviceID: setup.context.localID, epoch: setup.context.epoch, authKey: authKey().rawRepresentation) }
    }
    private func device() throws -> PairDevice {
        guard let setup, let cipher else { throw SpaceError.missingRecord }
        return PairDevice(deviceID: setup.context.localID, identityPublic: cipher.publicIdentity.base64EncodedString(), authPublicJwk: AuthPublic(try authKey()))
    }
    private func export<T: Encodable>(_ value: T) throws -> String { try HTTPRelay.encode(value).base64EncodedString() }
    private func parse<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard text.utf8.count < 32_000, let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SpaceError.invalidInput }
        return try JSONDecoder().decode(type, from: data)
    }
    private func digest(_ text: String) throws -> Data {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SpaceError.invalidInput }
        return Data(SHA256.hash(data: data))
    }
    public func status() -> (stage: String, output: String, owner: Bool, localID: UUID?, creator: Bool) {
        guard let setup else { return ("new", "", false, nil, false) }
        let output = setup.stage == "revoked" ? "" : setup.final ?? setup.response ?? setup.invitation ?? ""
        return (setup.stage, output, setup.context.cycleOwner == setup.context.localID, setup.context.localID, setup.creator)
    }
    public func invitationExpiry() throws -> Date? {
        if setup?.stage == "revoked" { return nil }
        guard let text = setup?.invitation else { return nil }
        return Date(timeIntervalSince1970: try parse(PairInvite.self, text).expires / 1000)
    }
    public func peerDeviceID() -> UUID? { setup?.context.peerID }
    public func verificationCode(response text: String? = nil) throws -> String? {
        guard let setup else { return nil }
        if setup.stage == "revoked" { return nil }
        try connect()
        let peerIdentity: Data
        if !setup.creator {
            guard let invitation = setup.invitation else { return nil }
            let invite = try parse(PairInvite.self, invitation)
            peerIdentity = invite.bundle.identity
        } else if let text, setup.stage == "invited" {
            guard let invitation = setup.invitation else { return nil }
            let response = try parse(PairResponse.self, text)
            guard response.version == 1, response.invitationDigest == (try digest(invitation)),
                  response.device.deviceID == setup.context.peerID,
                  let identity = Data(base64Encoded: response.device.identityPublic) else { throw SpaceError.unauthorized }
            peerIdentity = identity
        } else {
            guard let pinned = try cipher?.pinnedPeerIdentity() else { return nil }
            peerIdentity = pinned
        }
        return PairingVerification.code(pairID: setup.context.pairID, first: cipher!.publicIdentity, second: peerIdentity)
    }
    public func create(endpoint: URL, bootstrap: String, ownsCycle: Bool) async throws {
        guard !busy else { return }; busy = true; defer { busy = false }
        if setup == nil {
            _ = try HTTPRelay(baseURL: endpoint, deviceID: UUID(), authKey: authKey().rawRepresentation)
            let local = UUID(), peer = UUID()
            let context = try PairContext(pairID: UUID(), localID: local, peerID: peer, cycleOwner: ownsCycle ? local : peer)
            try save(PairSetup(context: context, endpoint: endpoint, creator: true, stage: "creating"))
        }
        guard var value = setup, value.creator, ["creating", "invited"].contains(value.stage) else { throw SpaceError.conflict }
        try connect(); let own = try device()
        struct Bootstrap: Encodable { let pairID: UUID; let device: PairDevice }
        do {
            _ = try await relay!.request("/v1/bootstrap", body: HTTPRelay.encode(Bootstrap(pairID: value.context.pairID, device: own)), authenticated: false, bearer: bootstrap)
        } catch let error as RelayHTTPError where error.status == 409 {
            // A lost bootstrap response is safe to retry only when authenticated status matches this device.
            try await verifyServer(own: own, peer: nil)
        }
        struct Invitation: Decodable { let invitation: String; let expires: Double }
        let remote = try JSONDecoder().decode(Invitation.self, from: await relay!.request("/v1/pair/invitations"))
        let invite = PairInvite(version: 1, endpoint: value.endpoint, context: value.context, device: own, bundle: try cipher!.createBundle(), invitation: remote.invitation, expires: remote.expires)
        value.invitation = try export(invite); value.stage = "invited"; try save(value)
    }
    public func join(_ text: String) async throws {
        guard !busy else { return }; busy = true; defer { busy = false }
        let invite = try parse(PairInvite.self, text)
        guard invite.version == 1, invite.context.epoch == 1, invite.context.localID == invite.device.deviceID,
              invite.device.identityPublic == invite.bundle.identity.base64EncodedString(), invite.context.localID != invite.context.peerID else { throw SpaceError.unauthorized }
        guard invite.expires > Date().timeIntervalSince1970 * 1000 else { throw SpaceError.expired }
        let context = try PairContext(pairID: invite.context.pairID, localID: invite.context.peerID, peerID: invite.context.localID, cycleOwner: invite.context.cycleOwner)
        if setup == nil {
            _ = try HTTPRelay(baseURL: invite.endpoint, deviceID: context.localID, authKey: authKey().rawRepresentation)
            try save(PairSetup(context: context, endpoint: invite.endpoint, creator: false, stage: "joining", invitation: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard var value = setup, !value.creator, value.context == context, try digest(value.invitation!) == digest(text), value.stage == "joining" else { throw SpaceError.conflict }
        try connect(); let own = try device()
        struct Join: Encodable { let invitation: String; let device: PairDevice }
        struct Joined: Decodable { let pairID: UUID; let epoch: UInt64; let peer: PairDevice }
        let joined = try JSONDecoder().decode(Joined.self, from: await relay!.request("/v1/pair/join", body: HTTPRelay.encode(Join(invitation: invite.invitation, device: own)), authenticated: false))
        guard joined.pairID == context.pairID, joined.epoch == context.epoch, joined.peer == invite.device else { throw SpaceError.unauthorized }
        try cipher!.pinVerifiedIdentity(invite.bundle.identity)
        if try db.entries("sessions").isEmpty { try cipher!.establish(with: invite.bundle) }
        try db.transaction {
            let hash = try digest(text)
            let packet = try cipher!.encrypt(HTTPRelay.encode(Confirmation(purpose: "join", invitationDigest: hash, responder: own)))
            value.response = try export(PairResponse(version: 1, invitationDigest: hash, device: own, packet: packet))
            value.stage = "responded"
            try db.encode(value, table: "network", key: "setup")
        }
        setup = value
    }
    public func acceptResponse(_ text: String) async throws {
        guard !busy else { return }; busy = true; defer { busy = false }
        guard var value = setup, value.creator, let invitation = value.invitation else { throw SpaceError.conflict }
        try connect()
        if value.stage == "invited" {
            let response = try parse(PairResponse.self, text), hash = try digest(invitation)
            guard response.version == 1, response.invitationDigest == hash, response.device.deviceID == value.context.peerID,
                  let identity = Data(base64Encoded: response.device.identityPublic) else { throw SpaceError.unauthorized }
            try await verifyServer(own: device(), peer: response.device)
            try cipher!.pinVerifiedIdentity(identity)
            try db.transaction {
                let confirmation = try JSONDecoder().decode(Confirmation.self, from: cipher!.decrypt(response.packet))
                guard confirmation == Confirmation(purpose: "join", invitationDigest: hash, responder: response.device) else { throw SpaceError.unauthorized }
                let reply = try cipher!.encrypt(HTTPRelay.encode(Confirmation(purpose: "accept", invitationDigest: hash, responder: response.device)))
                value.final = try export(PairFinal(version: 1, invitationDigest: hash, packet: reply))
                value.stage = "confirming"
                try db.encode(value, table: "network", key: "setup")
            }
            setup = value
        }
        guard value.stage == "confirming" else { throw SpaceError.conflict }
        struct Confirmed: Decodable { let active: Bool }
        let confirmed = try JSONDecoder().decode(Confirmed.self, from: await relay!.request("/v1/pair/confirm"))
        value.stage = confirmed.active ? "paired" : "awaitingPeer"
        try save(value)
    }
    public func acceptFinal(_ text: String) async throws {
        guard !busy else { return }; busy = true; defer { busy = false }
        guard var value = setup, !value.creator, let invitation = value.invitation else { throw SpaceError.conflict }
        try connect()
        if value.stage == "responded" {
            let final = try parse(PairFinal.self, text), hash = try digest(invitation)
            guard final.version == 1, final.invitationDigest == hash else { throw SpaceError.unauthorized }
            try db.transaction {
                let confirmation = try JSONDecoder().decode(Confirmation.self, from: cipher!.decrypt(final.packet))
                guard confirmation == Confirmation(purpose: "accept", invitationDigest: hash, responder: try device()) else { throw SpaceError.unauthorized }
                value.stage = "confirming"; try db.encode(value, table: "network", key: "setup")
            }
            setup = value
        }
        guard value.stage == "confirming" else { throw SpaceError.conflict }
        struct Confirmed: Decodable { let active: Bool }
        let confirmed = try JSONDecoder().decode(Confirmed.self, from: await relay!.request("/v1/pair/confirm"))
        value.stage = confirmed.active ? "paired" : "awaitingPeer"
        try save(value)
    }
    @discardableResult public func activateWhenReady() async throws -> Bool {
        guard var value = setup, value.stage == "awaitingPeer" else { return setup?.stage == "paired" }
        try connect()
        struct Status: Decodable { let pairID: UUID; let epoch: UInt64; let active: Bool; let devices: [PairDevice] }
        let remote = try JSONDecoder().decode(Status.self, from: await relay!.request("/v1/pair/status", method: "GET"))
        guard remote.pairID == value.context.pairID, remote.epoch == value.context.epoch,
              remote.devices.contains(try device()),
              let peer = remote.devices.first(where: { $0.deviceID == value.context.peerID }),
              let pinned = try cipher!.pinnedPeerIdentity(), peer.identityPublic == pinned.base64EncodedString() else {
            throw SpaceError.unauthorized
        }
        guard remote.active else { return false }
        value.stage = "paired"; try save(value)
        return true
    }
    private func verifyServer(own: PairDevice, peer: PairDevice?) async throws {
        struct Status: Decodable { let pairID: UUID; let epoch: UInt64; let devices: [PairDevice] }
        let status = try JSONDecoder().decode(Status.self, from: await relay!.request("/v1/pair/status", method: "GET"))
        guard let setup, status.pairID == setup.context.pairID, status.epoch == setup.context.epoch,
              status.devices.contains(own), peer == nil || status.devices.contains(peer!) else { throw SpaceError.unauthorized }
    }
    private func client() throws -> SyncCoordinator {
        guard let setup, setup.stage == "paired" else { throw SpaceError.unauthorized }
        try connect()
        if coordinator == nil { coordinator = try SyncCoordinator(db: db, cipher: cipher!, pair: setup.context) }
        return coordinator!
    }
    private func markRevoked() throws {
        guard var value = setup, value.stage != "revoked" else { return }
        mediaSocket?.cancel(with: .goingAway, reason: nil)
        mediaSocket = nil
        value.stage = "revoked"
        value.invitation = nil; value.response = nil; value.final = nil
        try save(value)
    }
    /// A changed server epoch is a definitive revocation signal. Other auth/network errors
    /// remain retryable and must not discard the local pairing state.
    public func checkPairStatus() async throws {
        guard let value = setup, value.stage == "paired" else { return }
        try connect()
        struct Status: Decodable { let pairID: UUID; let epoch: UInt64; let active: Bool; let devices: [PairDevice] }
        do {
            let remote = try JSONDecoder().decode(Status.self, from: await relay!.request("/v1/pair/status", method: "GET"))
            guard remote.pairID == value.context.pairID,
                  remote.devices.contains(try device()),
                  let peer = remote.devices.first(where: { $0.deviceID == value.context.peerID }),
                  let pinned = try cipher!.pinnedPeerIdentity(), peer.identityPublic == pinned.base64EncodedString() else {
                throw SpaceError.unauthorized
            }
            if remote.epoch != value.context.epoch || !remote.active { try markRevoked() }
        } catch is RelayEpochChanged {
            try markRevoked()
        }
    }
    public func revokePairing() async throws {
        guard setup?.stage == "paired" else { throw SpaceError.notPaired }
        try connect()
        do {
            _ = try await relay!.request("/v1/pair/revoke")
            try markRevoked()
        } catch {
            // If the response was lost after the server committed, the new epoch confirms it.
            try await checkPairStatus()
            if setup?.stage != "revoked" { throw error }
        }
    }
    public func synchronize() async throws {
        try await checkPairStatus()
        let client = try client()
        try await client.sync(using: relay!)
        // The mailbox carries only the signed manifest. The photo bytes pass through
        // a live socket and are never added to the server's durable storage.
        do {
            try await ensureMediaSocket()
            for id in try await client.missingPeerPhotoIDs() {
                try await mediaSocket?.send(.string("need:\(id.uuidString)"))
            }
        } catch {
            mediaSocket?.cancel(with: .goingAway, reason: nil)
            mediaSocket = nil
            // Text synchronization remains available when the live media channel is offline.
        }
    }
    private func ensureMediaSocket() async throws {
        guard mediaSocket == nil, let relay else { return }
        let socket = try await relay.openMediaSocket()
        mediaSocket = socket
        Task { [weak self] in await self?.readMediaSocket(socket) }
    }
    private func readMediaSocket(_ socket: URLSessionWebSocketTask) async {
        while mediaSocket === socket {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let request):
                    guard request.hasPrefix("need:"),
                          let id = UUID(uuidString: String(request.dropFirst(5))),
                          let sealed = try await client().photoCiphertext(id) else { continue }
                    var frame = Data("photo:\(id.uuidString):".utf8)
                    frame.append(sealed)
                    try await socket.send(.data(frame))
                case .data(let frame):
                    guard frame.count >= 44,
                          let header = String(data: frame.prefix(43), encoding: .utf8),
                          header.hasPrefix("photo:"), header.hasSuffix(":"),
                          let id = UUID(uuidString: String(header.dropFirst(6).dropLast())) else { continue }
                    try await client().receivePhotoCiphertext(Data(frame.dropFirst(43)), id: id)
                    try await client().sync(using: relay!)
                @unknown default: break
                }
            } catch {
                break
            }
        }
        if mediaSocket === socket { mediaSocket = nil }
    }
    public func state() async throws -> SharedState { try await client().state() }
    public func retainedState() async throws -> SharedState {
        guard let setup, setup.stage == "revoked" else { throw SpaceError.notPaired }
        try connect()
        if coordinator == nil { coordinator = try SyncCoordinator(db: db, cipher: cipher!, pair: setup.context) }
        return try await coordinator!.state()
    }
    public func privateCycle() async throws -> CycleEntry? { try await client().privateCycle() }
    public func saveCycle(_ entry: CycleEntry) async throws { try await client().saveCycle(entry) }
    public func capsuleDrafts() async throws -> [CapsuleDraft] { try await client().capsuleDrafts() }
    public func saveCapsuleDraft(_ value: CapsuleDraft) async throws { try await client().saveCapsuleDraft(value) }
    public func sealCapsuleDraft(_ value: CapsuleDraft) async throws { try await client().sealCapsuleDraft(value) }
    public func discardCapsuleDraft(_ id: UUID) async throws { try await client().discardCapsuleDraft(id) }
    public func prepareCapsuleDraft(_ value: CapsuleDraft) async throws -> CapsuleDraft { try await client().prepareCapsuleDraft(value) }
    public func openedCapsules() async throws -> Set<UUID> { try await client().openedCapsules() }
    public func openCapsule(_ id: UUID) async throws { try await client().openCapsule(id) }
    public func openWishReminder(_ id: UUID) async throws { try await client().openWishReminder(id) }
    public func createEvent(_ payload: EventPayload, objectID: UUID = UUID()) async throws { _ = try await client().create(payload, objectID: objectID) }
    public func createPhoto(_ jpeg: Data, width: Int, height: Int) async throws {
        _ = try await client().createPhoto(jpeg, width: width, height: height)
    }
    public func createSticker(_ data: Data, kind: String, width: Int, height: Int) async throws {
        _ = try await client().createSticker(data, kind: kind, width: width, height: height)
    }
    public func createMemoryWithPhoto(_ memory: MemoryContent, jpeg: Data,
                                      width: Int, height: Int, id: UUID) async throws {
        _ = try await client().createWithPhoto(.journal(.memory(memory)), jpeg: jpeg,
                                               width: width, height: height,
                                               objectID: id, destination: .memory)
    }
    public func updateProfile(name: String, avatar: (jpeg: Data, width: Int, height: Int)?,
                              retainedAvatarID: UUID?) async throws {
        try await client().updateProfile(name: name, avatar: avatar, retainedAvatarID: retainedAvatarID)
    }
    public func photoData(_ id: UUID) async throws -> Data? { try await client().photoData(id) }
    public func pendingCount() async throws -> Int { try await client().unconfirmedEventCount() }
    public func sendAffection(_ kind: AffectionKind) async throws -> Bool { try await client().sendAffection(kind) }
    public func respondToAffection(_ id: UUID) async throws -> Bool { try await client().respondToAffection(envelopeID: id) }
    #if DEBUG
    public func latestAffectionActionID() async throws -> UUID? { try await client().latestAffectionActionID() }
    #endif
    public func registerPush(token: String?, environment: String, affection: Bool = false, messages: Bool = false, wishes: Bool = false) async throws {
        _ = try client()
        guard let relay else { throw SpaceError.notPaired }
        if let token {
            struct Registration: Encodable { let token: String; let environment: String; let alertsEnabled: Bool; let messageAlertsEnabled: Bool; let wishAlertsEnabled: Bool }
            _ = try await relay.request("/v1/device/push-token", method: "PUT", body: HTTPRelay.encode(Registration(token: token, environment: environment, alertsEnabled: affection, messageAlertsEnabled: messages, wishAlertsEnabled: wishes)))
        } else { _ = try await relay.request("/v1/device/push-token", method: "DELETE") }
    }
    public func takeAffections() async throws -> [Affection] { try await client().takeAffections() }
    public func deliveries() async throws -> [UUID: DeliveryState] { try await client().deliveries() }
    public func reminderIntents() async throws -> [ReminderIntent] { try await client().reminders() }
    public func resetReminderWindow() async throws { try await client().resetFutureReminderPlans() }
    public func planReminder(wishID: UUID, days: Int, quiet: QuietHours = QuietHours()) async throws -> ReminderIntent {
        let start = Date().addingTimeInterval(60)
        return try await client().planReminder(wishID: wishID,
            allowed: quiet.allowedIntervals(start: start, days: days), sample: Double.random(in: 0..<1))
    }
}
