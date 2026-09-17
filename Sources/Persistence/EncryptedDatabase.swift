import Foundation
import CSQLCipher
import Domain

public enum DatabaseError: Error, Equatable { case open, key, statement, read, transaction, cipherUnavailable }

/// Actor-confined by SyncCoordinator. No open SQLite handle escapes this type.
public final class EncryptedDatabase: TransactionalStore {
    private var db: OpaquePointer?
    private var inTransaction = false
    public var failNextCommit = false // deterministic local fault-injection, never a network control
    public let url: URL
    public init(url: URL, key: Data) throws {
        guard key.count == 32 else { throw DatabaseError.key }
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; throw DatabaseError.open
        }
        do {
            guard key.withUnsafeBytes({ sqlite3_key(db, $0.baseAddress, Int32(key.count)) }) == SQLITE_OK else {
                throw DatabaseError.key
            }
            guard try scalarText("PRAGMA cipher_version;")?.hasPrefix("4.") == true else { throw DatabaseError.cipherUnavailable }
            try execute("PRAGMA cipher_memory_security=ON;")
            try execute("PRAGMA temp_store=MEMORY;")
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("CREATE TABLE IF NOT EXISTS records (namespace TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(namespace,key)) WITHOUT ROWID;")
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var directory = url.deletingLastPathComponent(); try directory.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
            }
            #endif
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !inTransaction else { throw DatabaseError.transaction }
        try execute("BEGIN IMMEDIATE;"); inTransaction = true
        defer { inTransaction = false }
        do {
            let value = try body()
            if failNextCommit { failNextCommit = false; throw SpaceError.injectedFailure }
            try execute("COMMIT;")
            return value
        } catch { try? execute("ROLLBACK;"); throw error }
    }
    public func read(_ table: String, key: String) throws -> Data? {
        let stmt = try prepare("SELECT value FROM records WHERE namespace=? AND key=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(table, at: 1, to: stmt); try bind(key, at: 2, to: stmt)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return blob(stmt, column: 0)
        case SQLITE_DONE: return nil
        default: throw DatabaseError.read
        }
    }
    public func write(_ table: String, key: String, value: Data) throws {
        guard inTransaction else { throw DatabaseError.transaction }
        let stmt = try prepare("INSERT INTO records(namespace,key,value) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value;")
        defer { sqlite3_finalize(stmt) }
        try bind(table, at: 1, to: stmt); try bind(key, at: 2, to: stmt)
        let rc = value.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(value.count), transient) }
        guard rc == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.statement }
    }
    public func remove(_ table: String, key: String) throws {
        guard inTransaction else { throw DatabaseError.transaction }
        let stmt = try prepare("DELETE FROM records WHERE namespace=? AND key=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(table, at: 1, to: stmt); try bind(key, at: 2, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.statement }
    }
    public func entries(_ table: String) throws -> [(String, Data)] {
        let stmt = try prepare("SELECT key,value FROM records WHERE namespace=? ORDER BY key;")
        defer { sqlite3_finalize(stmt) }; try bind(table, at: 1, to: stmt)
        var result: [(String, Data)] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(stmt, 0) else { throw DatabaseError.read }
                result.append((String(cString: text), blob(stmt, column: 1)))
            case SQLITE_DONE: return result
            default: throw DatabaseError.read
            }
        }
    }
    public func cipherVersion() throws -> String { try scalarText("PRAGMA cipher_version;") ?? "" }
    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private func bind(_ value: String, at index: Int32, to stmt: OpaquePointer) throws {
        guard value.withCString({ sqlite3_bind_text(stmt, index, $0, -1, transient) }) == SQLITE_OK else { throw DatabaseError.statement }
    }
    private func blob(_ stmt: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.statement }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.statement }
    }
    private func scalarText(_ sql: String) throws -> String? {
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }
}
