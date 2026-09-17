import Foundation
import Persistence
import Crypto

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("couple-lab-\(UUID())")
let db = try EncryptedDatabase(url: directory.appendingPathComponent("private.sqlite"), key: secureRandomKey())
print("SQLCipher \(try db.cipherVersion()) — encrypted database opened")
