import Foundation

public enum ListCategory: String, Codable, CaseIterable, Sendable {
    case eat = "想吃", visit = "想去", watch = "想看", buy = "想买", doTogether = "想做"
}

public struct ChecklistContent: Codable, Equatable, Sendable {
    public var text: String
    public var category: ListCategory
    public var completed: Bool
    public var deleted: Bool
    public init(text: String, category: ListCategory, completed: Bool = false, deleted: Bool = false) {
        self.text = text; self.category = category; self.completed = completed; self.deleted = deleted
    }
}

public struct MemoryContent: Codable, Equatable, Sendable {
    public var title: String
    public var text: String
    public var date: Date
    public var sourceID: UUID?
    /// References the already shared encrypted photo; no image bytes enter this event.
    public var mediaID: UUID?
    public var deleted: Bool
    public init(title: String, text: String, date: Date, sourceID: UUID? = nil,
                mediaID: UUID? = nil, deleted: Bool = false) {
        self.title = title; self.text = text; self.date = date
        self.sourceID = sourceID; self.mediaID = mediaID; self.deleted = deleted
    }
}

/// Access is time-gated in the normal app, not cryptographic time-lock encryption.
public struct CapsuleContent: Codable, Equatable, Sendable {
    public let title: String
    public let text: String
    public let mediaID: UUID?
    public let opensAt: Date
    /// The first contribution reserves the companion's object ID; the companion refers back to it.
    public let partnerSlotID: UUID?
    public let companionOf: UUID?
    public init(title: String, text: String, opensAt: Date, partnerSlotID: UUID? = nil,
                companionOf: UUID? = nil, mediaID: UUID? = nil) {
        self.title = title; self.text = text; self.opensAt = opensAt
        self.partnerSlotID = partnerSlotID; self.companionOf = companionOf; self.mediaID = mediaID
    }
}

public enum JournalOperation: Codable, Equatable, Sendable {
    case checklist(ChecklistContent)
    case memory(MemoryContent)
    case anniversary(AnniversaryContent)
    case sealCapsule(CapsuleContent)
    case cancelCapsule

    public func validate(createdAt: Date) throws {
        func text(_ value: String, max: Int = 16_384) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= max else { throw SpaceError.invalidInput }
        }
        switch self {
        case .anniversary(let item): try item.validate()
        case .checklist(let item): try text(item.text, max: 2_048)
        case .memory(let item):
            try text(item.title, max: 512)
            guard item.text.utf8.count <= 16_384, item.date.timeIntervalSince1970.isFinite,
                  item.mediaID == nil || item.mediaID == item.sourceID,
                  !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.mediaID != nil else {
                throw SpaceError.invalidInput
            }
        case .sealCapsule(let item):
            try text(item.title, max: 512)
            guard item.text.utf8.count <= 16_384,
                  !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.mediaID != nil,
                  item.opensAt.timeIntervalSince1970.isFinite, item.opensAt > createdAt else { throw SpaceError.invalidInput }
            guard item.partnerSlotID == nil || item.companionOf == nil else { throw SpaceError.invalidInput }
        case .cancelCapsule: break
        }
    }
}

public struct JournalRecord<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let author: UUID
    public let value: Value
    public let version: Version
    public let createdAt: Date
}

public struct JournalState: Codable, Equatable, Sendable {
    private var anniversaryStorage: [UUID: JournalRecord<AnniversaryContent>]?
    public var anniversaries: [UUID: JournalRecord<AnniversaryContent>] { anniversaryStorage ?? [:] }
    public private(set) var checklist: [UUID: JournalRecord<ChecklistContent>] = [:]
    public private(set) var memories: [UUID: JournalRecord<MemoryContent>] = [:]
    public private(set) var capsules: [UUID: JournalRecord<CapsuleContent>] = [:]
    // Keep author-scoped tombstones: a cancellation can arrive before its capsule.
    private var cancellations: [UUID: [UUID: Date]] = [:]
    public init() {}
    public func isCancelled(_ capsule: JournalRecord<CapsuleContent>) -> Bool {
        guard let date = cancellations[capsule.id]?[capsule.author] else { return false }
        return date >= capsule.createdAt && date < capsule.value.opensAt
    }
    public func canOpen(_ capsule: JournalRecord<CapsuleContent>, now: Date) -> Bool {
        isValidContribution(capsule) && !isCancelled(capsule) && now >= capsule.value.opensAt
    }
    public func isValidContribution(_ capsule: JournalRecord<CapsuleContent>) -> Bool {
        guard let parentID = capsule.value.companionOf else { return true }
        guard let first = capsules[parentID] else { return false }
        return first.value.companionOf == nil && first.value.partnerSlotID == capsule.id && first.author != capsule.author
            && first.value.opensAt == capsule.value.opensAt && first.value.title == capsule.value.title
    }
    public func contributions(to rootID: UUID) -> [JournalRecord<CapsuleContent>] {
        guard let root = capsules[rootID], root.value.companionOf == nil else { return [] }
        var result = [root]
        if let slot = root.value.partnerSlotID, let peer = capsules[slot], isValidContribution(peer) { result.append(peer) }
        return result
    }
    mutating func apply(_ operation: JournalOperation, event: DomainEvent) throws {
        switch operation {
        case .anniversary(let value):
            if let old = anniversaries[event.objectID], old.version >= event.version { return }
            var records = anniversaries
            records[event.objectID] = JournalRecord(id: event.objectID, author: event.author, value: value, version: event.version, createdAt: event.createdAt)
            anniversaryStorage = records
        case .checklist(let value):
            if let old = checklist[event.objectID], old.version >= event.version { return }
            checklist[event.objectID] = JournalRecord(id: event.objectID, author: event.author, value: value, version: event.version, createdAt: event.createdAt)
        case .memory(let value):
            if let old = memories[event.objectID], old.version >= event.version { return }
            memories[event.objectID] = JournalRecord(id: event.objectID, author: event.author, value: value, version: event.version, createdAt: event.createdAt)
        case .sealCapsule(let value):
            guard value.partnerSlotID != event.objectID, value.companionOf != event.objectID else { throw SpaceError.invalidInput }
            let record = JournalRecord(id: event.objectID, author: event.author, value: value, version: event.version, createdAt: event.createdAt)
            if let old = capsules[event.objectID], old != record { throw SpaceError.conflict }
            capsules[event.objectID] = record
        case .cancelCapsule:
            // Invalid attempts from the other author cannot cancel the owner's content,
            // irrespective of whether the seal event has arrived yet.
            var authors = cancellations[event.objectID] ?? [:]
            authors[event.author] = min(authors[event.author] ?? event.createdAt, event.createdAt)
            cancellations[event.objectID] = authors
        }
    }
}
