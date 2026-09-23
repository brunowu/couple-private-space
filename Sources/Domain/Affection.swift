import Foundation

public enum AffectionKind: String, Codable, CaseIterable, Sendable {
    case missYou = "想你了", hug = "抱抱", kiss = "亲亲", appreciation = "辛苦啦"
    public var symbol: String {
        switch self { case .missYou: "heart"; case .hug: "person.2"; case .kiss: "heart.circle"; case .appreciation: "sun.max" }
    }
}

/// Short-lived encrypted interaction, deliberately not a DomainEvent or chat message.
public struct Affection: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: AffectionKind
    public let createdAt: Date
    public let expiresAt: Date
    public init(id: UUID = UUID(), kind: AffectionKind, now: Date = Date()) {
        self.id = id; self.kind = kind; self.createdAt = now; self.expiresAt = now.addingTimeInterval(900)
    }
    public func validate(now: Date) throws {
        guard createdAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= 900,
              createdAt <= now.addingTimeInterval(60) else { throw SpaceError.invalidInput }
    }
}
