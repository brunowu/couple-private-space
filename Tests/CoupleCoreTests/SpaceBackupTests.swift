import XCTest
@testable import Application
import Crypto
import Domain
import Persistence

final class BackupVault: KeyVault {
    var values: [String: Data] = [:]
    func load(_ name: String) throws -> Data? { values[name] }
    func save(_ value: Data, name: String) throws {
        if let old = values[name], old != value { throw VaultError.invalidKey }
        values[name] = value
    }
}

final class SpaceBackupTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAuthenticatedBackupVerifiesAndRestoresOnlyToEmptyDestination() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 7, count: 32)
        let source = try EncryptedDatabase(url: root.appendingPathComponent("source.sqlite"), key: key)
        try source.transaction { try source.write("network", key: "setup", value: Data("paired".utf8)) }
        let snapshotURL = root.appendingPathComponent("snapshot.sqlite")
        try source.snapshot(to: snapshotURL, key: key)
        let localID = UUID(), peerID = UUID()
        let artifact = try SpaceBackupService.create(
            database: Data(contentsOf: snapshotURL), databaseKey: key,
            authKey: Data(repeating: 8, count: 32), identityKey: Data(repeating: 9, count: 32),
            localID: localID, peerID: peerID, state: SharedState(), outputDirectory: root)

        XCTAssertEqual(try SpaceBackupService.verify(fileURL: artifact.fileURL,
                                                      recoveryKey: artifact.recoveryKey), artifact.preview)
        let restored = root.appendingPathComponent("restored")
        let vault = BackupVault()
        let defaults = UserDefaults(suiteName: "backup-test-\(UUID().uuidString)")!
        XCTAssertEqual(try SpaceBackupService.restore(fileURL: artifact.fileURL,
                                                       recoveryKey: artifact.recoveryKey,
                                                       directory: restored, vault: vault,
                                                       defaults: defaults), artifact.preview)
        XCTAssertEqual(vault.values["network.database"], key)
        let restoredDB = try EncryptedDatabase(url: restored.appendingPathComponent("network.sqlite"), key: key)
        XCTAssertEqual(try restoredDB.read("network", key: "setup"), Data("paired".utf8))
        XCTAssertThrowsError(try SpaceBackupService.restore(fileURL: artifact.fileURL,
                                                             recoveryKey: artifact.recoveryKey,
                                                             directory: restored, vault: vault,
                                                             defaults: defaults)) {
            XCTAssertEqual($0 as? SpaceBackupError, .destinationNotEmpty)
        }
    }

    func testWrongKeyAndTamperingAreRejected() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 3, count: 32)
        let db = try EncryptedDatabase(url: root.appendingPathComponent("source.sqlite"), key: key)
        try db.transaction { try db.write("network", key: "setup", value: Data("paired".utf8)) }
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try db.snapshot(to: snapshot, key: key)
        let artifact = try SpaceBackupService.create(database: Data(contentsOf: snapshot), databaseKey: key,
                                                      authKey: Data([1]), identityKey: Data([2]),
                                                      localID: UUID(), peerID: UUID(), state: SharedState(),
                                                      outputDirectory: root)
        let wrong = "CPS1-" + Data(repeating: 1, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try SpaceBackupService.verify(fileURL: artifact.fileURL, recoveryKey: wrong)) {
            XCTAssertEqual($0 as? SpaceBackupError, .authenticationFailed)
        }
        var damaged = try Data(contentsOf: artifact.fileURL)
        damaged[damaged.index(before: damaged.endIndex)] ^= 0x01
        let damagedURL = root.appendingPathComponent("damaged.couplebackup")
        try damaged.write(to: damagedURL)
        XCTAssertThrowsError(try SpaceBackupService.verify(fileURL: damagedURL,
                                                            recoveryKey: artifact.recoveryKey)) {
            XCTAssertEqual($0 as? SpaceBackupError, .authenticationFailed)
        }
    }
}
