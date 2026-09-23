import Foundation
import CryptoKit
import Domain
import Crypto
import Persistence

public enum SpaceBackupError: Error, Equatable {
    case invalidFile, invalidRecoveryKey, authenticationFailed, damagedPayload
    case incompleteIdentity, destinationNotEmpty, tooLarge
}

private struct BackupHeader: Codable {
    let version: Int
    let cipher: String
}

private enum BackupPreference: Codable {
    case bool(Bool), integer(Int), string(String)
}

private struct BackupPayload: Codable {
    let preview: SpaceBackupPreview
    let database: Data
    let databaseSHA256: Data
    let secrets: [String: Data]
    let preferences: [String: BackupPreference]
}

enum SpaceBackupService {
    private static let magic = Data("CPSBACKUP1\0".utf8)
    private static let maximumBytes = 1_073_741_824
    static let preferenceKeys = [
        "affection-haptics", "affection-push-enabled", "message-push-enabled", "wish-push-enabled",
        "capsule-reminders-enabled", "anniversary-reminders-enabled", "anniversary-reminder-days",
        "chat-last-read-clock", "chat-read-clock-initialized", "wish-quiet-enabled", "wish-quiet-start",
        "wish-quiet-end", "wish-reminder-days", "wish-reminder-time-zone", "wish-reminders-enabled",
        "private-app-lock-enabled"
    ]

    static func create(database: Data, databaseKey: Data, authKey: Data, identityKey: Data,
                       localID: UUID, peerID: UUID, state: SharedState,
                       defaults: UserDefaults = .standard, outputDirectory: URL) throws -> SpaceBackupArtifact {
        guard databaseKey.count == 32, !authKey.isEmpty, !identityKey.isEmpty else { throw SpaceBackupError.incompleteIdentity }
        guard database.count <= maximumBytes else { throw SpaceBackupError.tooLarge }
        let now = Date()
        let preview = SpaceBackupPreview(createdAt: now, localDeviceID: localID, peerDeviceID: peerID,
                                         messageCount: state.messages.count, photoCount: state.media.count,
                                         wishCount: state.wishes.count, databaseBytes: database.count)
        var preferences: [String: BackupPreference] = [:]
        for name in preferenceKeys {
            guard let value = defaults.object(forKey: name) else { continue }
            if let value = value as? Bool { preferences[name] = .bool(value) }
            else if let value = value as? Int { preferences[name] = .integer(value) }
            else if let value = value as? String { preferences[name] = .string(value) }
        }
        let payload = BackupPayload(preview: preview, database: database,
                                    databaseSHA256: Data(SHA256.hash(data: database)),
                                    secrets: ["network.database": databaseKey, "network.auth": authKey,
                                              "identity.\(localID.uuidString)": identityKey],
                                    preferences: preferences)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let plaintext = try encoder.encode(payload)
        guard plaintext.count <= maximumBytes else { throw SpaceBackupError.tooLarge }
        // The cleartext header contains only format negotiation. Device IDs and counts stay encrypted.
        let header = BackupHeader(version: 1, cipher: "AES-256-GCM")
        let headerData = try JSONEncoder().encode(header)
        let keyData = try secureRandomKey()
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData), authenticating: headerData)
        guard let combined = sealed.combined else { throw SpaceBackupError.damagedPayload }
        var archive = magic
        var headerLength = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &headerLength) { archive.append(contentsOf: $0) }
        archive.append(headerData); archive.append(combined)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = outputDirectory.appendingPathComponent("我们-加密备份-\(stamp).couplebackup")
        try archive.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let recovery = "CPS1-" + keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // Read the finished file again and authenticate it before presenting it to the user.
        _ = try verify(fileURL: url, recoveryKey: recovery)
        return SpaceBackupArtifact(fileURL: url, recoveryKey: recovery, preview: preview)
    }

    static func verify(fileURL: URL, recoveryKey: String) throws -> SpaceBackupPreview {
        try decode(fileURL: fileURL, recoveryKey: recoveryKey).preview
    }

    /// Restore is deliberately restricted to an empty destination and an empty vault.
    static func restore(fileURL: URL, recoveryKey: String, directory: URL, vault: any KeyVault,
                        defaults: UserDefaults = .standard) throws -> SpaceBackupPreview {
        let payload = try decode(fileURL: fileURL, recoveryKey: recoveryKey)
        let destination = directory.appendingPathComponent("network.sqlite")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SpaceBackupError.destinationNotEmpty }
        for name in payload.secrets.keys where try vault.load(name) != nil { throw SpaceBackupError.destinationNotEmpty }
        guard let databaseKey = payload.secrets["network.database"] else { throw SpaceBackupError.incompleteIdentity }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".restore-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        try payload.database.write(to: staging, options: [.atomic])
        let check = try EncryptedDatabase(url: staging, key: databaseKey)
        guard try check.read("network", key: "setup") != nil else { throw SpaceBackupError.damagedPayload }
        for (name, value) in payload.secrets { try vault.save(value, name: name) }
        try FileManager.default.moveItem(at: staging, to: destination)
        for (name, value) in payload.preferences {
            switch value {
            case .bool(let value): defaults.set(value, forKey: name)
            case .integer(let value): defaults.set(value, forKey: name)
            case .string(let value): defaults.set(value, forKey: name)
            }
        }
        return payload.preview
    }

    private static func decode(fileURL: URL, recoveryKey: String) throws -> BackupPayload {
        let archive = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard archive.count > magic.count + 4 + 28, archive.count <= maximumBytes,
              archive.prefix(magic.count) == magic else { throw SpaceBackupError.invalidFile }
        let lengthRange = magic.count..<(magic.count + 4)
        let headerLength = archive[lengthRange].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let headerStart = magic.count + 4, headerEnd = headerStart + Int(headerLength)
        guard headerLength > 0, headerLength < 65_536, headerEnd < archive.count else { throw SpaceBackupError.invalidFile }
        let headerData = archive.subdata(in: headerStart..<headerEnd)
        let header = try JSONDecoder().decode(BackupHeader.self, from: headerData)
        guard header.version == 1, header.cipher == "AES-256-GCM" else { throw SpaceBackupError.invalidFile }
        let keyData = try parseRecoveryKey(recoveryKey)
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.SealedBox(combined: archive.subdata(in: headerEnd..<archive.count)) }
        catch { throw SpaceBackupError.invalidFile }
        let plaintext: Data
        do { plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: headerData) }
        catch { throw SpaceBackupError.authenticationFailed }
        let payload = try PropertyListDecoder().decode(BackupPayload.self, from: plaintext)
        guard payload.database.count <= maximumBytes,
              Data(SHA256.hash(data: payload.database)) == payload.databaseSHA256,
              payload.preview.databaseBytes == payload.database.count,
              payload.secrets["network.database"]?.count == 32,
              payload.secrets["network.auth"] != nil,
              payload.secrets["identity.\(payload.preview.localDeviceID.uuidString)"] != nil else {
            throw SpaceBackupError.damagedPayload
        }
        return payload
    }

    private static func parseRecoveryKey(_ value: String) throws -> Data {
        guard value.hasPrefix("CPS1-") else { throw SpaceBackupError.invalidRecoveryKey }
        var encoded = String(value.dropFirst(5)).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count == 32 else { throw SpaceBackupError.invalidRecoveryKey }
        return data
    }
}
