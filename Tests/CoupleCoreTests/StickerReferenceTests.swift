import XCTest
@testable import Domain

final class StickerReferenceTests: XCTestCase {
    func testRoundTripsContentAddressedStickerID() {
        let id = "sha256:" + String(repeating: "a", count: 64)
        let message = StickerReference.message(for: id)
        XCTAssertEqual(message.flatMap(StickerReference.stickerID(from:)), id)
    }

    func testRejectsMalformedReferencesAndOrdinaryMessages() {
        XCTAssertNil(StickerReference.message(for: "sticker-1"))
        XCTAssertNil(StickerReference.stickerID(from: "哈哈哈"))
        XCTAssertNil(StickerReference.stickerID(from: "couple-private-sticker:v1:sha256:abc"))
    }
}
