import Foundation
import AppKit
import Testing
import Domain
import Crypto
import Persistence
import Sync

@Test func photoMetadataNeverCountsAsDeliveryBeforeAuthenticatedBytesArrive() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
    let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    let event = try await c.a.createPhoto(jpeg, width: 2, height: 2)
    let memory = MemoryContent(title: "一起留下的照片", text: "", date: Date(),
                               sourceID: event.objectID, mediaID: event.objectID)
    _ = try await c.a.create(.journal(.memory(memory)), objectID: event.objectID)
    if case .media(let manifest) = event.payload {
        await #expect(throws: SpaceError.invalidInput) { try await c.a.create(.media(manifest)) }
    } else { Issue.record("photo did not create a media event") }
    #expect(try await c.a.photoData(event.objectID) == jpeg)
    #expect(try c.dbA.read("mediaBlobs", key: event.objectID.uuidString) != jpeg)
    try await c.a.sync(using: c.relay)
    try await c.b.sync(using: c.relay)
    try await c.a.sync(using: c.relay)
    #expect(try await c.b.state().media[event.objectID] != nil)
    #expect(try await c.b.state().journal.memories[event.objectID]?.value.mediaID == event.objectID)
    #expect(try await c.b.photoData(event.objectID) == nil)
    #expect(try await c.a.delivery(event.id) == .uploaded)
    let sealed = try #require(try await c.a.photoCiphertext(event.objectID))
    var damaged = sealed; damaged[damaged.count - 1] ^= 1
    await #expect(throws: (any Error).self) { try await c.b.receivePhotoCiphertext(damaged, id: event.objectID) }
    #expect(try await c.b.photoData(event.objectID) == nil)
    try await c.b.receivePhotoCiphertext(sealed, id: event.objectID)
    #expect(try await c.b.photoData(event.objectID) == jpeg)
    #expect(try await c.b.state().journal.memories[event.objectID]?.value.title == memory.title)
    try await c.b.sync(using: c.relay); try await c.a.sync(using: c.relay)
    #expect(try await c.a.delivery(event.id) == .delivered)
    let reopened = try EncryptedDatabase(url: c.dbB.url, key: c.keyB)
    let cipher = try SignalSession(db: reopened, vault: c.vaultB, localID: c.pairB.localID, peerID: c.pairB.peerID)
    let restored = try SyncCoordinator(db: reopened, cipher: cipher, pair: c.pairB)
    #expect(try await restored.photoData(event.objectID) == jpeg)
    #expect(try await restored.state().journal.memories[event.objectID]?.value.mediaID == event.objectID)
}

@Test func directPhotoMemoryIsAtomicAndDoesNotBecomeChatPhoto() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
    let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    let id = UUID()
    let invalid = MemoryContent(title: "", text: "", date: Date(), sourceID: id, mediaID: id)
    await #expect(throws: SpaceError.invalidInput) {
        try await c.a.createWithPhoto(.journal(.memory(invalid)), jpeg: jpeg,
                                      width: 2, height: 2, objectID: id, destination: .memory)
    }
    #expect(try await c.a.state().media[id] == nil)
    #expect(try c.dbA.read("mediaBlobs", key: id.uuidString) == nil)
    let memory = MemoryContent(title: "这一刻", text: "", date: Date(), sourceID: id, mediaID: id)
    _ = try await c.a.createWithPhoto(.journal(.memory(memory)), jpeg: jpeg,
                                      width: 2, height: 2, objectID: id, destination: .memory)
    #expect(try await c.a.state().media[id]?.destination == .memory)
    #expect(try await c.a.state().journal.memories[id]?.value.text == "")
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.state().media[id]?.destination == .memory)
    #expect(try await c.b.state().journal.memories[id]?.value.mediaID == id)
    #expect(try await c.b.photoData(id) == nil)
    try await c.b.receivePhotoCiphertext(try #require(try await c.a.photoCiphertext(id)), id: id)
    #expect(try await c.b.photoData(id) == jpeg)
}

@Test func photoOnlyCapsuleDraftRestoresAndStaysHiddenUntilOpening() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
    let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    let draft = CapsuleDraft(title: "给未来", text: "", opensAt: Date().addingTimeInterval(3_600),
                             photoJPEG: jpeg, photoWidth: 2, photoHeight: 2)
    try await c.a.saveCapsuleDraft(draft)
    let reopened = try EncryptedDatabase(url: c.dbA.url, key: c.keyA)
    let cipher = try SignalSession(db: reopened, vault: c.vaultA, localID: c.pairA.localID, peerID: c.pairA.peerID)
    let restored = try SyncCoordinator(db: reopened, cipher: cipher, pair: c.pairA)
    #expect(try await restored.capsuleDrafts().first?.photoJPEG == jpeg)
    try await restored.sealCapsuleDraft(draft)
    #expect(try await restored.capsuleDrafts().isEmpty)
    #expect(try await restored.state().media[draft.id]?.destination == .capsule)
    #expect(try await restored.state().journal.capsules[draft.id]?.value.mediaID == draft.id)
    try await restored.sync(using: c.relay); try await c.b.sync(using: c.relay)
    let peer = try await c.b.state()
    let capsule = try #require(peer.journal.capsules[draft.id])
    #expect(!peer.journal.canOpen(capsule, now: Date()))
    #expect(peer.media[draft.id]?.destination == .capsule)
    #expect(try await c.b.photoData(draft.id) == nil)
    try await c.b.receivePhotoCiphertext(try #require(try await restored.photoCiphertext(draft.id)), id: draft.id)
    #expect(try await c.b.photoData(draft.id) == jpeg)
}

@Test func audioAndVideoAttachmentsUseTheExistingEncryptedMediaPipeline() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let video = Data(repeating: 0x5a, count: 4_096)
    let memoryID = UUID()
    let memory = MemoryContent(title: "一段视频", text: "", date: Date(),
                               sourceID: memoryID, mediaID: memoryID)
    _ = try await c.a.createWithMedia(.journal(.memory(memory)), data: video, kind: "video/mp4",
                                      width: 720, height: 1_280, objectID: memoryID, destination: .memory)
    let draft = CapsuleDraft(title: "未来的视频", text: "", opensAt: Date().addingTimeInterval(3_600),
                             videoData: video, videoKind: "video/mp4", videoWidth: 720, videoHeight: 1_280)
    try await c.a.saveCapsuleDraft(draft)
    try await c.a.sealCapsuleDraft(draft)
    #expect(try await c.a.state().media[memoryID]?.manifest.kind == "video/mp4")
    #expect(try await c.a.state().media[draft.id]?.destination == .capsule)
    #expect(try await c.a.photoData(memoryID) == video)
    #expect(try await c.a.photoData(draft.id) == video)
    let audio = Data(repeating: 0x33, count: 2_048)
    let audioEvent = try await c.a.createSticker(audio, kind: "audio/mp4", width: 1, height: 1)
    #expect(try await c.a.state().media[audioEvent.objectID]?.manifest.kind == "audio/mp4")
    #expect(try await c.a.photoData(audioEvent.objectID) == audio)
}

@Test func namesAndAvatarsSyncAsEncryptedProfilesWithoutChatArtifacts() async throws {
    let c = try Clients(); defer { try? FileManager.default.removeItem(at: c.dir) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
    let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    await #expect(throws: SpaceError.invalidInput) { try await c.a.updateProfile(name: " ") }
    try await c.a.updateProfile(name: "小吴", avatar: (jpeg, 2, 2))
    let local = try #require(try await c.a.state().profiles[c.pairA.localID])
    let avatarID = try #require(local.value.avatarID)
    #expect(try await c.a.state().media[avatarID]?.destination == .avatar)
    #expect(try await c.a.state().messages.isEmpty)
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.state().profiles[c.pairA.localID]?.value.name == "小吴")
    #expect(try await c.b.photoData(avatarID) == nil)
    try await c.b.receivePhotoCiphertext(try #require(try await c.a.photoCiphertext(avatarID)), id: avatarID)
    #expect(try await c.b.photoData(avatarID) == jpeg)
    try await c.a.updateProfile(name: "吴", retainedAvatarID: avatarID)
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.state().profiles[c.pairA.localID]?.value.name == "吴")
    #expect(try await c.b.state().profiles[c.pairA.localID]?.value.avatarID == avatarID)
    try await c.a.updateProfile(name: "吴", retainedAvatarID: nil)
    try await c.a.sync(using: c.relay); try await c.b.sync(using: c.relay)
    #expect(try await c.b.state().profiles[c.pairA.localID]?.value.avatarID == nil)
    #expect(try await c.b.state().messages.isEmpty)
}
