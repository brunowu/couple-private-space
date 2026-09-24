import Foundation
import Testing
import Domain
import Application
import CoreImage.CIFilterBuiltins
import Vision
import AppKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["COUPLE_HTTP_TEST_URL"] != nil))
func independentClientsPairOverHTTPAndRecoverAfterRestart() async throws {
    let base = URL(string: ProcessInfo.processInfo.environment["COUPLE_HTTP_TEST_URL"]!)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-test-\(UUID())")
    let va = TestVault(), vb = TestVault()
    var a: NetworkPair? = try NetworkPair(directory: directory.appendingPathComponent("a"), vault: va)
    var b: NetworkPair? = try NetworkPair(directory: directory.appendingPathComponent("b"), vault: vb)
    try await a!.create(endpoint: base, bootstrap: "local-simulator-only", ownsCycle: false)
    let invitation = await a!.status().output
    #expect(try await a!.invitationExpiry()! > Date())
    let invitationQR = try PairingQRCode.encode(invitation)
    #expect(invitationQR.utf8.count <= 4_296)
    #expect(try PairingQRCode.decode(invitationQR) == invitation)
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(invitationQR.utf8)
    filter.correctionLevel = "L"
    let image = try #require(filter.outputImage)
    let cgImage = try #require(CIContext().createCGImage(image.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), from: image.extent.applying(CGAffineTransform(scaleX: 5, y: 5))))
    let scan = VNDetectBarcodesRequest()
    scan.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: cgImage).perform([scan])
    #expect(scan.results?.first?.payloadStringValue == invitationQR)
    try await b!.join(invitation)
    let response = await b!.status().output
    let codeOnB = try await b!.verificationCode()
    let codeOnA = try await a!.verificationCode(response: response)
    #expect(codeOnA == codeOnB)
    #expect(codeOnA != nil)
    // Corrupting a response must not advance the pairing or consume the session.
    var object = try JSONSerialization.jsonObject(with: Data(base64Encoded: response)!) as! [String: Any]
    object["invitationDigest"] = Data(repeating: 0, count: 32).base64EncodedString()
    let tampered = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
    await #expect(throws: (any Error).self) { try await a!.acceptResponse(tampered) }
    #expect(await a!.status().stage == "invited")
    try await a!.acceptResponse(response)
    #expect(await a!.status().stage == "awaitingPeer")
    #expect(try await a!.activateWhenReady() == false)
    #expect(try await a!.verificationCode() == codeOnB)
    try await b!.acceptFinal(await a!.status().output)
    #expect(try await a!.activateWhenReady())
    #expect(await a!.status().stage == "paired")
    #expect(await a!.status().localID != b!.status().localID)
    try await a!.createEvent(.message(text: "HTTP-only message"))
    try await a!.synchronize(); try await b!.synchronize(); try await a!.synchronize()
    #expect(try await b!.state().messages.values.contains { $0.text == "HTTP-only message" })
    #expect(try await a!.pendingCount() == 0)
    // Offline local write survives the client being closed and reopened.
    try await b!.createEvent(.wishCreated(text: "Offline wish"))
    a = nil; b = nil
    a = try NetworkPair(directory: directory.appendingPathComponent("a"), vault: va)
    b = try NetworkPair(directory: directory.appendingPathComponent("b"), vault: vb)
    try await b!.synchronize(); try await a!.synchronize(); try await b!.synchronize()
    #expect(try await a!.state().wishes.values.contains { $0.text == "Offline wish" })
    #expect(try await b!.pendingCount() == 0)
    let owner = await b!.status().localID!
    try await b!.createEvent(.cycle(SharedCycleProjection(owner: owner, generation: 1, revision: 1, startDate: "2026-09-11", revoked: false)))
    try await b!.synchronize(); try await a!.synchronize()
    #expect(try await a!.state().cycle?.startDate == "2026-09-11")
    try await b!.createEvent(.cycle(SharedCycleProjection(owner: owner, generation: 2, revision: 1, startDate: nil, revoked: true)))
    try await b!.synchronize(); try await a!.synchronize()
    #expect(try await a!.state().cycle?.revoked == true)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
    let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    try await a!.createPhoto(jpeg, width: 2, height: 2)
    let ownMediaID = try #require(try await a!.state().media.keys.first)
    try await a!.createEvent(.journal(.memory(MemoryContent(title: "一起留下的照片", text: "",
                                                           date: Date(), sourceID: ownMediaID,
                                                           mediaID: ownMediaID))), objectID: ownMediaID)
    try await a!.synchronize(); try await b!.synchronize(); try await a!.synchronize()
    #expect(try await b!.state().media.count == 1)
    let mediaID = try #require(try await b!.state().media.keys.first)
    #expect(try await b!.state().journal.memories[mediaID]?.value.mediaID == mediaID)
    for _ in 0..<30 {
        if try await b!.photoData(mediaID) != nil { break }
        try await Task.sleep(for: .milliseconds(200))
        try await b!.synchronize()
    }
    #expect(try await b!.photoData(mediaID) == jpeg)
    try await a!.synchronize()
    #expect(try await a!.pendingCount() == 0)
    let directID = UUID()
    let directMemory = MemoryContent(title: "直接保存的照片", text: "", date: Date(),
                                     sourceID: directID, mediaID: directID)
    try await a!.createMemoryWithPhoto(directMemory, jpeg: jpeg, width: 2, height: 2, id: directID)
    let photoDraft = CapsuleDraft(title: "未来的照片", text: "",
                                  opensAt: Date().addingTimeInterval(3_600),
                                  photoJPEG: jpeg, photoWidth: 2, photoHeight: 2)
    try await a!.saveCapsuleDraft(photoDraft)
    try await a!.sealCapsuleDraft(photoDraft)
    try await a!.synchronize(); try await b!.synchronize()
    for _ in 0..<30 {
        let memoryPhoto = try await b!.photoData(directID)
        let capsulePhoto = try await b!.photoData(photoDraft.id)
        if memoryPhoto != nil && capsulePhoto != nil { break }
        try await Task.sleep(for: .milliseconds(200))
        try await b!.synchronize()
    }
    #expect(try await b!.photoData(directID) == jpeg)
    #expect(try await b!.photoData(photoDraft.id) == jpeg)
    #expect(try await b!.state().media[directID]?.destination == .memory)
    #expect(try await b!.state().media[photoDraft.id]?.destination == .capsule)
    let receivedCapsule = try #require(try await b!.state().journal.capsules[photoDraft.id])
    #expect(!((try await b!.state()).journal.canOpen(receivedCapsule, now: Date())))
    try await a!.synchronize()
    #expect(try await a!.pendingCount() == 0)
    try await a!.updateProfile(name: "小吴", avatar: (jpeg, 2, 2), retainedAvatarID: nil)
    try await b!.updateProfile(name: "小卡", avatar: nil, retainedAvatarID: nil)
    let aID = try #require(await a!.status().localID)
    let bID = try #require(await b!.status().localID)
    let avatarID = try #require(try await a!.state().profiles[aID]?.value.avatarID)
    try await a!.synchronize(); try await b!.synchronize(); try await a!.synchronize()
    for _ in 0..<30 {
        if try await b!.photoData(avatarID) != nil { break }
        try await Task.sleep(for: .milliseconds(200)); try await b!.synchronize()
    }
    #expect(try await b!.state().profiles[aID]?.value.name == "小吴")
    #expect(try await a!.state().profiles[bID]?.value.name == "小卡")
    #expect(try await b!.photoData(avatarID) == jpeg)
    #expect(try await b!.state().media[avatarID]?.destination == .avatar)
    try await b!.revokePairing()
    #expect(await b!.status().stage == "revoked")
    #expect(await b!.status().output.isEmpty)
    try await a!.checkPairStatus()
    #expect(await a!.status().stage == "revoked")
    #expect(try await a!.retainedState().messages.values.contains { $0.text == "HTTP-only message" })
    await #expect(throws: (any Error).self) { try await a!.createEvent(.message(text: "must not send")) }
    await #expect(throws: (any Error).self) { try await a!.synchronize() }
    a = nil; b = nil
    a = try NetworkPair(directory: directory.appendingPathComponent("a"), vault: va)
    b = try NetworkPair(directory: directory.appendingPathComponent("b"), vault: vb)
    #expect(await a!.status().stage == "revoked")
    #expect(await b!.status().stage == "revoked")
    #expect(try await b!.retainedState().wishes.values.contains { $0.text == "Offline wish" })
}
