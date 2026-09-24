import Foundation

/// Device-private draft. Never sent until the explicit seal action creates a shared event.
public struct CapsuleDraft: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let generation: UUID?
    public var title: String
    public var text: String
    public var photoJPEG: Data?
    public var photoWidth: Int?
    public var photoHeight: Int?
    public var videoData: Data?
    public var videoKind: String?
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var opensAt: Date
    public var partnerSlotID: UUID?
    public var companionOf: UUID?
    public var revision: UInt64
    public init(id: UUID = UUID(), title: String = "", text: String = "", opensAt: Date = Date().addingTimeInterval(86_400),
                partnerSlotID: UUID? = nil, companionOf: UUID? = nil, revision: UInt64 = 0,
                photoJPEG: Data? = nil, photoWidth: Int? = nil, photoHeight: Int? = nil,
                videoData: Data? = nil, videoKind: String? = nil, videoWidth: Int? = nil, videoHeight: Int? = nil) {
        self.id = id; self.generation = UUID(); self.title = title; self.text = text; self.opensAt = opensAt
        self.partnerSlotID = partnerSlotID; self.companionOf = companionOf; self.revision = revision
        self.photoJPEG = photoJPEG; self.photoWidth = photoWidth; self.photoHeight = photoHeight
        self.videoData = videoData; self.videoKind = videoKind
        self.videoWidth = videoWidth; self.videoHeight = videoHeight
    }
    public var content: CapsuleContent {
        CapsuleContent(title: title, text: text, opensAt: opensAt, partnerSlotID: partnerSlotID,
                       companionOf: companionOf, mediaID: photoJPEG == nil && videoData == nil ? nil : id)
    }
    public func validate() throws {
        guard title.utf8.count <= 512, text.utf8.count <= 16_384, opensAt.timeIntervalSince1970.isFinite,
              revision < UInt64.max, partnerSlotID == nil || companionOf == nil,
              partnerSlotID != id, companionOf != id else { throw SpaceError.invalidInput }
        guard photoJPEG == nil || videoData == nil else { throw SpaceError.invalidInput }
        if let photoJPEG {
            guard (1...2_000_000).contains(photoJPEG.count),
                  let photoWidth, (1...4_096).contains(photoWidth),
                  let photoHeight, (1...4_096).contains(photoHeight) else { throw SpaceError.invalidInput }
        } else if photoWidth != nil || photoHeight != nil { throw SpaceError.invalidInput }
        if let videoData {
            guard (1...(25 * 1024 * 1024)).contains(videoData.count),
                  ["video/quicktime", "video/mp4"].contains(videoKind),
                  let videoWidth, (1...4_096).contains(videoWidth),
                  let videoHeight, (1...4_096).contains(videoHeight) else { throw SpaceError.invalidInput }
        } else if videoKind != nil || videoWidth != nil || videoHeight != nil { throw SpaceError.invalidInput }
    }
}
