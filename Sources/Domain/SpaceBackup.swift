import Foundation

public struct SpaceBackupPreview: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let localDeviceID: UUID
    public let peerDeviceID: UUID
    public let messageCount: Int
    public let photoCount: Int
    public let wishCount: Int
    public let databaseBytes: Int

    public init(createdAt: Date, localDeviceID: UUID, peerDeviceID: UUID,
                messageCount: Int, photoCount: Int, wishCount: Int, databaseBytes: Int) {
        self.createdAt = createdAt
        self.localDeviceID = localDeviceID
        self.peerDeviceID = peerDeviceID
        self.messageCount = messageCount
        self.photoCount = photoCount
        self.wishCount = wishCount
        self.databaseBytes = databaseBytes
    }
}

public struct SpaceBackupArtifact: Sendable {
    public let fileURL: URL
    public let recoveryKey: String
    public let preview: SpaceBackupPreview

    public init(fileURL: URL, recoveryKey: String, preview: SpaceBackupPreview) {
        self.fileURL = fileURL
        self.recoveryKey = recoveryKey
        self.preview = preview
    }
}
