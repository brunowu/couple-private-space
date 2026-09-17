import Foundation
import Testing
import Application

@Test func pairingCodeIsSymmetricAndBoundToBothIdentities() {
    let pair = UUID(uuidString: "4E8BC1A7-9B8D-4568-BC62-A473E1231D00")!
    let first = Data(repeating: 0x41, count: 33)
    let second = Data(repeating: 0x42, count: 33)
    let code = PairingVerification.code(pairID: pair, first: first, second: second)
    #expect(code == PairingVerification.code(pairID: pair, first: second, second: first))
    #expect(code.split(separator: " ").count == 4)
    #expect(code != PairingVerification.code(pairID: pair, first: first, second: Data(repeating: 0x43, count: 33)))
    #expect(code != PairingVerification.code(pairID: UUID(), first: first, second: second))
}

@Test func compactPairingQRRoundTripsExactPayloadAndRejectsGarbage() throws {
    let publicDocument = Data("{\"version\":1,\"bundle\":\"".utf8) + Data(repeating: 0x55, count: 1_800) + Data("\"}".utf8)
    let payload = publicDocument.base64EncodedString()
    let qr = try PairingQRCode.encode(payload)
    #expect(qr.hasPrefix("CPS1:"))
    #expect(try PairingQRCode.decode(qr) == payload)
    #expect(throws: (any Error).self) { try PairingQRCode.decode("CPS1:not-base64") }
}
