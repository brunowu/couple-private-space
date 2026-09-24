import Foundation

public enum SpaceError: Error, Equatable {
    case invalidInput, unauthorized, conflict, unsupportedVersion, notPaired
    case missingRecord, invalidEnvelope, capacity, expired, injectedFailure
}

public enum WishStatus: String, Codable, Sendable { case active, fulfilled, deferred, archived }
public enum DeliveryState: String, Codable, Sendable { case local, encrypted, uploaded, delivered }

public struct Version: Codable, Equatable, Comparable, Sendable {
    public let clock: UInt64
    public let author: UUID
    public let event: UUID
    public init(clock: UInt64, author: UUID, event: UUID) {
        self.clock = clock; self.author = author; self.event = event
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.clock != rhs.clock { return lhs.clock < rhs.clock }
        if lhs.author != rhs.author { return lhs.author.uuidString < rhs.author.uuidString }
        return lhs.event.uuidString < rhs.event.uuidString
    }
}

/// Private records deliberately do NOT conform to the shared event payload type.
public struct PrivateCycleRecord: Codable, Equatable, Sendable {
    public var startDate: String
    public var endDate: String?
    public var note: String?
    public init(startDate: String, endDate: String? = nil, note: String? = nil) {
        self.startDate = startDate; self.endDate = endDate; self.note = note
    }
}

public struct SharedCycleProjection: Codable, Equatable, Sendable {
    public let owner: UUID
    public let generation: UInt64
    public let revision: UInt64
    public let startDate: String?
    public let endDate: String?
    public let revoked: Bool
    public let estimatedNextDate: String?
    public let stage: String?
    public init(owner: UUID, generation: UInt64, revision: UInt64,
                startDate: String?, endDate: String? = nil, revoked: Bool = false,
                estimatedNextDate: String? = nil, stage: String? = nil) {
        self.owner = owner; self.generation = generation; self.revision = revision
        self.startDate = startDate; self.endDate = endDate; self.revoked = revoked
        self.estimatedNextDate = estimatedNextDate; self.stage = stage
    }
    public func validate() throws {
        guard generation > 0, revision > 0 else { throw SpaceError.invalidInput }
        if revoked {
            guard startDate == nil, endDate == nil, estimatedNextDate == nil, stage == nil else { throw SpaceError.invalidInput }
        } else {
            guard startDate != nil || estimatedNextDate != nil || stage != nil,
                  startDate.map(Self.isDate) ?? true, estimatedNextDate.map(Self.isDate) ?? true,
                  stage.map({ ["尚未记录结束", "已记录结束"].contains($0) }) ?? true else { throw SpaceError.invalidInput }
            if let endDate { guard let startDate, Self.isDate(endDate), endDate >= startDate else { throw SpaceError.invalidInput } }
        }
    }
    private static func isDate(_ value: String) -> Bool {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0); f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return value.count == 10 && f.date(from: value).map { f.string(from: $0) == value } == true
    }
}

public enum EventPayload: Codable, Equatable, Sendable {
    case message(text: String)
    case messageV2(MessageContent)
    case chatReaction(ChatReactionContent)
    case media(MediaManifest)
    case profile(ProfileContent)
    case wishCreated(text: String)
    case wishStatus(WishStatus)
    case cycle(SharedCycleProjection)
    case journal(JournalOperation)
}

public struct MessageContent: Codable, Equatable, Sendable {
    public let text: String
    public let replyTo: UUID?
    public init(text: String, replyTo: UUID? = nil) {
        self.text = text; self.replyTo = replyTo
    }
}

public enum ChatReaction: String, Codable, CaseIterable, Equatable, Sendable {
    case heart, laugh, kiss, pleading, thumbsUp, hug
    public var symbol: String {
        switch self {
        case .heart: "❤️"
        case .laugh: "😂"
        case .kiss: "😘"
        case .pleading: "🥺"
        case .thumbsUp: "👍"
        case .hug: "🫂"
        }
    }
}

public struct ChatReactionContent: Codable, Equatable, Sendable {
    public let targetID: UUID
    /// Nil removes this author's existing reaction while preserving an ordering tombstone.
    public let reaction: ChatReaction?
    public init(targetID: UUID, reaction: ChatReaction?) {
        self.targetID = targetID; self.reaction = reaction
    }
}

public struct ChatReactionRecord: Codable, Equatable, Sendable {
    public let targetID: UUID
    public let author: UUID
    public let reaction: ChatReaction?
    public let version: Version
    public init(targetID: UUID, author: UUID, reaction: ChatReaction?, version: Version) {
        self.targetID = targetID; self.author = author; self.reaction = reaction; self.version = version
    }
}

/// Sent through the Signal session; the media bytes themselves never enter the mailbox.
public enum MediaDestination: String, Codable, Equatable, Sendable {
    case chat, memory, capsule, avatar
}

public struct ProfileContent: Codable, Equatable, Sendable {
    public let name: String
    public let avatarID: UUID?
    public init(name: String, avatarID: UUID? = nil) {
        self.name = name; self.avatarID = avatarID
    }
    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 24, name.utf8.count <= 96,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SpaceError.invalidInput
        }
    }
}

public struct SharedProfile: Codable, Equatable, Sendable {
    public let author: UUID
    public let value: ProfileContent
    public let version: Version
}

public struct MediaManifest: Codable, Equatable, Sendable {
    public let kind: String
    public let byteCount: Int
    public let width: Int
    public let height: Int
    public let sha256: Data
    public let fileKey: Data
    /// Nil is a legacy chat photo. New attachments name their owning surface.
    public let destination: MediaDestination?
    public init(byteCount: Int, width: Int, height: Int, sha256: Data, fileKey: Data,
                destination: MediaDestination? = nil, kind: String = "image/jpeg") {
        self.kind = kind; self.byteCount = byteCount
        self.width = width; self.height = height; self.sha256 = sha256; self.fileKey = fileKey
        self.destination = destination
    }
    public func validate() throws {
        let maximum = kind == "image/jpeg" ? 2_000_000 : 10 * 1024 * 1024
        guard ["image/jpeg", "image/png", "image/gif"].contains(kind),
              (1...maximum).contains(byteCount),
              (1...4_096).contains(width), (1...4_096).contains(height),
              sha256.count == 32, fileKey.count == 32 else { throw SpaceError.invalidInput }
    }
}

public struct MediaAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let author: UUID
    public let manifest: MediaManifest
    public let version: Version
    public let createdAt: Date?
    public var destination: MediaDestination { manifest.destination ?? .chat }
    public init(id: UUID, author: UUID, manifest: MediaManifest, version: Version,
                createdAt: Date? = nil) {
        self.id = id; self.author = author; self.manifest = manifest
        self.version = version; self.createdAt = createdAt
    }
}

public struct DomainEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let objectID: UUID
    public let author: UUID
    public let sequence: UInt64
    public let lamport: UInt64
    public let createdAt: Date
    public let payload: EventPayload
    public let schemaVersion: Int
    public init(id: UUID = UUID(), objectID: UUID = UUID(), author: UUID,
                sequence: UInt64, lamport: UInt64, createdAt: Date, payload: EventPayload) {
        self.id = id; self.objectID = objectID; self.author = author
        self.sequence = sequence; self.lamport = lamport; self.createdAt = createdAt
        self.payload = payload
        if case .media(let manifest) = payload { self.schemaVersion = manifest.destination == .avatar ? 7 : manifest.destination == nil ? 5 : 6
        } else if case .profile = payload { self.schemaVersion = 7
        } else if case .journal(.memory(let memory)) = payload, memory.mediaID != nil { self.schemaVersion = 6
        } else if case .journal(.sealCapsule(let capsule)) = payload, capsule.mediaID != nil { self.schemaVersion = 6
        } else if case .journal(.anniversary) = payload { self.schemaVersion = 4
        } else if case .cycle(let value) = payload, value.estimatedNextDate != nil || value.stage != nil || (!value.revoked && value.startDate == nil) {
            self.schemaVersion = 4
        } else if case .journal(.sealCapsule(let capsule)) = payload, capsule.partnerSlotID != nil || capsule.companionOf != nil {
            self.schemaVersion = 3
        } else if case .messageV2 = payload { self.schemaVersion = 8
        } else if case .chatReaction = payload { self.schemaVersion = 8
        } else if case .journal = payload { self.schemaVersion = 2 } else { self.schemaVersion = 1 }
    }
    public var version: Version { Version(clock: lamport, author: author, event: id) }
    public func validate(cycleOwner: UUID?) throws {
        guard (1...8).contains(schemaVersion) else { throw SpaceError.unsupportedVersion }
        guard sequence > 0, lamport > 0, lamport < UInt64.max, sequence < UInt64.max,
              createdAt.timeIntervalSince1970.isFinite else { throw SpaceError.invalidInput }
        switch payload {
        case .media(let manifest):
            guard schemaVersion >= 5 else { throw SpaceError.unsupportedVersion }
            if manifest.destination != nil { guard schemaVersion >= 6 else { throw SpaceError.unsupportedVersion } }
            if manifest.destination == .avatar { guard schemaVersion >= 7 else { throw SpaceError.unsupportedVersion } }
            try manifest.validate()
        case .profile(let profile):
            guard schemaVersion >= 7, profile.avatarID == nil || profile.avatarID == objectID else { throw SpaceError.invalidInput }
            try profile.validate()
        case .message(let text), .wishCreated(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 16_384 else { throw SpaceError.invalidInput }
        case .messageV2(let content):
            guard schemaVersion >= 8, content.replyTo != objectID,
                  !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  content.text.utf8.count <= 16_384 else { throw SpaceError.invalidInput }
        case .chatReaction(let content):
            guard schemaVersion >= 8, content.targetID == objectID else { throw SpaceError.invalidInput }
        case .wishStatus: break
        case .journal(let operation):
            guard schemaVersion >= 2 else { throw SpaceError.unsupportedVersion }
            if case .memory(let memory) = operation, let mediaID = memory.mediaID {
                guard mediaID == objectID else { throw SpaceError.invalidInput }
            }
            if case .sealCapsule(let capsule) = operation, let mediaID = capsule.mediaID {
                guard mediaID == objectID else { throw SpaceError.invalidInput }
            }
            if case .anniversary = operation { guard schemaVersion >= 4 else { throw SpaceError.unsupportedVersion } }
            if case .sealCapsule(let capsule) = operation, capsule.partnerSlotID != nil || capsule.companionOf != nil {
                guard schemaVersion >= 3 else { throw SpaceError.unsupportedVersion }
            }
            try operation.validate(createdAt: createdAt)
        case .cycle(let projection):
            if projection.estimatedNextDate != nil || projection.stage != nil || (!projection.revoked && projection.startDate == nil) {
                guard schemaVersion >= 4 else { throw SpaceError.unsupportedVersion }
            }
            guard author == cycleOwner, projection.owner == author else { throw SpaceError.unauthorized }
            try projection.validate()
        }
    }
}

public struct Message: Codable, Equatable, Sendable {
    public let id: UUID
    public let author: UUID
    public let text: String
    public let version: Version
    /// Nil only for materialized views written by versions before message timestamps.
    public let createdAt: Date?
    public let replyTo: UUID?
    public init(id: UUID, author: UUID, text: String, version: Version, createdAt: Date? = nil,
                replyTo: UUID? = nil) {
        self.id = id; self.author = author; self.text = text
        self.version = version; self.createdAt = createdAt; self.replyTo = replyTo
    }
}
public struct Wish: Codable, Equatable, Sendable {
    public let id: UUID
    public let creator: UUID
    public let text: String
    public var status: WishStatus
    public var statusVersion: Version
    /// Time of the winning fulfilled operation; absent for legacy snapshots or other statuses.
    public var completedAt: Date?
}

/// Rebuildable materialized view. State events may arrive before creation events.
public struct SharedState: Codable, Equatable, Sendable {
    public private(set) var messages: [UUID: Message] = [:]
    public private(set) var wishes: [UUID: Wish] = [:]
    public private(set) var cycle: SharedCycleProjection?
    private var pendingStatuses: [UUID: StatusValue] = [:]
    // Optional storage lets existing encrypted v1 materialized views decode without migration loss.
    private var journalStorage: JournalState?
    public var journal: JournalState { journalStorage ?? JournalState() }
    private var mediaStorage: [UUID: MediaAsset]?
    public var media: [UUID: MediaAsset] { mediaStorage ?? [:] }
    private var profileStorage: [UUID: SharedProfile]?
    public var profiles: [UUID: SharedProfile] { profileStorage ?? [:] }
    private var chatReactionStorage: [UUID: [UUID: ChatReactionRecord]]?
    public var chatReactions: [UUID: [UUID: ChatReactionRecord]] { chatReactionStorage ?? [:] }
    private struct StatusValue: Codable, Equatable { let status: WishStatus; let version: Version; var completedAt: Date? }
    public init() {}
    public mutating func apply(_ event: DomainEvent, cycleOwner: UUID?) throws {
        try event.validate(cycleOwner: cycleOwner)
        switch event.payload {
        case .profile(let profile):
            var values = profiles
            if let old = values[event.author], old.version >= event.version { return }
            values[event.author] = SharedProfile(author: event.author, value: profile, version: event.version)
            profileStorage = values
        case .media(let manifest):
            var assets = media
            let value = MediaAsset(id: event.objectID, author: event.author, manifest: manifest,
                                   version: event.version, createdAt: event.createdAt)
            if let old = assets[value.id], old != value { throw SpaceError.conflict }
            assets[value.id] = value; mediaStorage = assets
        case .journal(let operation):
            var value = journal; try value.apply(operation, event: event); journalStorage = value
        case .message(let text):
            let value = Message(id: event.objectID, author: event.author, text: text,
                                version: event.version, createdAt: event.createdAt)
            if let old = messages[value.id], old != value { throw SpaceError.conflict }
            messages[value.id] = value
        case .messageV2(let content):
            let value = Message(id: event.objectID, author: event.author, text: content.text,
                                version: event.version, createdAt: event.createdAt,
                                replyTo: content.replyTo)
            if let old = messages[value.id], old != value { throw SpaceError.conflict }
            messages[value.id] = value
        case .chatReaction(let content):
            var all = chatReactions
            var target = all[content.targetID] ?? [:]
            if let old = target[event.author], old.version >= event.version { return }
            target[event.author] = ChatReactionRecord(targetID: content.targetID, author: event.author,
                                                       reaction: content.reaction, version: event.version)
            all[content.targetID] = target
            chatReactionStorage = all
        case .wishCreated(let text):
            if let old = wishes[event.objectID] {
                guard old.creator == event.author, old.text == text else { throw SpaceError.conflict }
                return
            }
            var wish = Wish(id: event.objectID, creator: event.author, text: text,
                            status: .active, statusVersion: event.version)
            if let pending = pendingStatuses[event.objectID], pending.version > wish.statusVersion {
                wish.status = pending.status; wish.statusVersion = pending.version
                wish.completedAt = pending.completedAt
            }
            wishes[wish.id] = wish
        case .wishStatus(let status):
            if let old = pendingStatuses[event.objectID], old.version >= event.version { return }
            let completedAt = status == .fulfilled ? event.createdAt : nil
            pendingStatuses[event.objectID] = StatusValue(status: status, version: event.version, completedAt: completedAt)
            if var wish = wishes[event.objectID], event.version > wish.statusVersion {
                wish.status = status; wish.statusVersion = event.version; wish.completedAt = completedAt; wishes[wish.id] = wish
            }
        case .cycle(let value):
            if let old = cycle {
                let incoming = (value.generation, value.revision), current = (old.generation, old.revision)
                if incoming < current { return }
                if incoming == current {
                    guard value == old else { throw SpaceError.conflict }
                    return
                }
            }
            cycle = value
        }
    }
}
