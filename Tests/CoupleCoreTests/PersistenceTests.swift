import Foundation
import Testing
import Domain
import Crypto
import Persistence

@Test func encryptedDatabaseRejectsWrongKeyAndRollsBack() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("private.sqlite"), key = try secureRandomKey()
    var db: EncryptedDatabase? = try EncryptedDatabase(url: url, key: key)
    #expect(try db!.cipherVersion().hasPrefix("4.19.0"))
    let sensitive = Data("PRIVATE_SENTINEL_do_not_store_plaintext_月经备注".utf8)
    try db!.transaction { try db!.write("events", key: "1", value: sensitive) }
    db!.failNextCommit = true
    #expect(throws: SpaceError.injectedFailure) {
        try db!.transaction { try db!.write("events", key: "2", value: sensitive) }
    }
    #expect(try db!.read("events", key: "2") == nil)
    for name in ["private.sqlite", "private.sqlite-wal"] {
        let bytes = try Data(contentsOf: dir.appendingPathComponent(name))
        #expect(bytes.range(of: sensitive) == nil)
        #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
    }
    db = nil
    #expect(throws: (any Error).self) { _ = try EncryptedDatabase(url: url, key: secureRandomKey()) }
    let reopened = try EncryptedDatabase(url: url, key: key)
    #expect(try reopened.read("events", key: "1") == sensitive)
}
