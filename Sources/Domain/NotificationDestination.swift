import Foundation

public struct NotificationDestination: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case message, wish, capsule, anniversary }
    public let kind: Kind
    public let objectID: UUID?
    public let id: UUID
    public init(kind: Kind, objectID: UUID? = nil) { self.kind = kind; self.objectID = objectID; self.id = UUID() }
}
