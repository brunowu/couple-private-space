import Foundation

/// Implementations confine these synchronous operations to one actor/serial owner.
/// A transaction never suspends, so crypto callbacks share the same commit boundary.
public protocol TransactionalStore: AnyObject {
    func transaction<T>(_ body: () throws -> T) throws -> T
    func read(_ table: String, key: String) throws -> Data?
    func write(_ table: String, key: String, value: Data) throws
    func remove(_ table: String, key: String) throws
    func entries(_ table: String) throws -> [(String, Data)]
}
public extension TransactionalStore {
    func decode<T: Decodable>(_ type: T.Type, table: String, key: String) throws -> T? {
        try read(table, key: key).map { try JSONDecoder().decode(type, from: $0) }
    }
    func encode<T: Encodable>(_ value: T, table: String, key: String) throws {
        try write(table, key: key, value: JSONEncoder().encode(value))
    }
}

public struct PairContext: Codable, Equatable, Sendable {
    public let pairID: UUID
    public let epoch: UInt64
    public let localID: UUID
    public let peerID: UUID
    public let cycleOwner: UUID?
    public init(pairID: UUID, epoch: UInt64 = 1, localID: UUID, peerID: UUID, cycleOwner: UUID? = nil) throws {
        guard localID != peerID, epoch > 0,
              cycleOwner == nil || cycleOwner == localID || cycleOwner == peerID else { throw SpaceError.invalidInput }
        self.pairID = pairID; self.epoch = epoch; self.localID = localID; self.peerID = peerID; self.cycleOwner = cycleOwner
    }
}
