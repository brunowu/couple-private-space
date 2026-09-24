#if os(iOS)
import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import Domain

struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy)
        }
    }
}

enum VideoImport {
    struct Prepared { let data: Data; let width: Int; let height: Int }

    static func prepare(_ url: URL) async throws -> Prepared {
        let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...(25 * 1024 * 1024)).contains(byteCount) else { throw SpaceError.capacity }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 30 else { throw SpaceError.capacity }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpaceError.invalidInput }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = size.applying(transform)
        let width = Int(abs(transformed.width).rounded()), height = Int(abs(transformed.height).rounded())
        guard (1...4_096).contains(width), (1...4_096).contains(height) else { throw SpaceError.invalidInput }
        return Prepared(data: try Data(contentsOf: url, options: .mappedIfSafe), width: width, height: height)
    }
}
#endif
