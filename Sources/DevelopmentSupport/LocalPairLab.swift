#if DEBUG
import Foundation
import SwiftUI
import Domain
import Crypto
import Persistence
import Transport
import Sync
import Notification

/// Development-only in-process dual-client harness, not production pairing.
@MainActor public final class LocalPairLab: ObservableObject {
    @Published public private(set) var state = SharedState()
    @Published public private(set) var localID = UUID()
    @Published public var side = 0
    @Published public var online = true
    @Published public private(set) var ready = false
    @Published public private(set) var error: String?
    @Published public private(set) var pendingCount = 0
    @Published public private(set) var reminderCount = 0
    private var clients: [SyncCoordinator] = []
    private var contexts: [PairContext] = []
    private var relay: LocalMailbox?
    private var syncing = false
    public init() {}
    public func start() async {
        guard !ready else { return }
        do {
            let vault = KeychainVault(service: "private.couple.development-lab")
            let config: PairContext
            if let bytes = try vault.load("lab-context") { config = try JSONDecoder().decode(PairContext.self, from: bytes) }
            else {
                let a = UUID(), b = UUID()
                config = try PairContext(pairID: UUID(), localID: a, peerID: b, cycleOwner: b)
                try vault.save(JSONEncoder().encode(config), name: "lab-context")
            }
            let reverse = try PairContext(pairID: config.pairID, localID: config.peerID, peerID: config.localID, cycleOwner: config.cycleOwner)
            contexts = [config, reverse]
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DevelopmentPair")
            var databases: [EncryptedDatabase] = [], ciphers: [SignalSession] = []
            for (index, context) in contexts.enumerated() {
                let keyName = "database.\(index)"
                let key: Data
                if let saved = try vault.load(keyName) { key = saved }
                else { key = try secureRandomKey(); try vault.save(key, name: keyName) }
                let db = try EncryptedDatabase(url: support.appendingPathComponent("\(index)/private.sqlite"), key: key)
                let cipher = try SignalSession(db: db, vault: vault, localID: context.localID, peerID: context.peerID)
                databases.append(db); ciphers.append(cipher)
            }
            // Only the local harness has both clients. Real pairing must authenticate QR material.
            if try databases[0].read("lab", key: "paired") == nil {
                try ciphers[0].pinVerifiedIdentity(ciphers[1].publicIdentity)
                try ciphers[1].pinVerifiedIdentity(ciphers[0].publicIdentity)
                let bundle = try ciphers[1].createBundle()
                if try databases[0].entries("sessions").isEmpty { try ciphers[0].establish(with: bundle) }
                let expected = Data("couple-lab-confirmation:\(config.pairID)".utf8)
                let outbound = try databases[0].transaction { try ciphers[0].encrypt(expected) }
                try databases[1].transaction { guard try ciphers[1].decrypt(outbound) == expected else { throw SpaceError.unauthorized } }
                let reply = try databases[1].transaction { try ciphers[1].encrypt(expected) }
                try databases[0].transaction {
                    guard try ciphers[0].decrypt(reply) == expected else { throw SpaceError.unauthorized }
                    try databases[0].encode(true, table: "lab", key: "paired")
                }
            }
            clients = try contexts.enumerated().map { try SyncCoordinator(db: databases[$0.offset], cipher: ciphers[$0.offset], pair: $0.element) }
            relay = try LocalMailbox(pairID: config.pairID, members: [config.localID, config.peerID])
            ready = true; try await refresh(); await synchronize()
        } catch { self.error = "本地空间初始化失败：\(String(describing: type(of: error)))" }
    }
    public func selectSide(_ value: Int) async {
        guard (0...1).contains(value), ready else { return }
        side = value
        do { try await refresh() } catch { self.error = "读取本地数据失败" }
    }
    public func sendText(_ text: String) async { await create(.message(text: text)) }
    public func createWish(_ text: String) async { await create(.wishCreated(text: text)) }
    private func create(_ payload: EventPayload, objectID: UUID = UUID()) async {
        guard ready else { return }
        do {
            _ = try await clients[side].create(payload, objectID: objectID)
            try await refresh(); await synchronize()
        } catch { self.error = "未能保存，请检查输入或本地存储" }
    }
    public func changeWish(_ wish: Wish, to status: WishStatus) async { await create(.wishStatus(status), objectID: wish.id) }
    public func updateCycle(date: Date, share: Bool) async {
        guard side == 1, ready else { return }
        do {
            let existing = try await clients[side].state().cycle
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            let value = SharedCycleProjection(owner: contexts[side].localID, generation: (existing?.generation ?? 0) + 1,
                revision: 1, startDate: share ? formatter.string(from: date) : nil, revoked: !share)
            await create(.cycle(value))
        } catch { self.error = "未能更新周期共享" }
    }
    public func synchronize() async {
        guard ready, online, !syncing, let relay else { return }
        syncing = true; defer { syncing = false }
        do {
            for _ in 0..<2 { for client in clients { try await client.sync(using: relay) } }
            try await refresh(); error = nil
        } catch { self.error = "同步暂未完成，本地内容仍保留" }
    }
    private func refresh() async throws {
        localID = contexts[side].localID
        state = try await clients[side].state()
        pendingCount = try await clients[side].outgoing().count
        reminderCount = try await clients[side].reminders().filter { $0.state != .cancelled }.count
    }
}
#endif
