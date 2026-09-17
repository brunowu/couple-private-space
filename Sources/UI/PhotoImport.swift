#if os(iOS)
import Foundation
import UIKit
import Domain

enum PhotoImport {
    static func prepare(_ bytes: Data) throws -> (jpeg: Data, width: Int, height: Int) {
        guard let image = UIImage(data: bytes) else { throw SpaceError.invalidInput }
        let rawWidth = image.cgImage?.width ?? Int(image.size.width)
        let rawHeight = image.cgImage?.height ?? Int(image.size.height)
        let rotated = [UIImage.Orientation.left, .leftMirrored, .right, .rightMirrored].contains(image.imageOrientation)
        let sourceWidth = rotated ? rawHeight : rawWidth
        let sourceHeight = rotated ? rawWidth : rawHeight
        guard sourceWidth > 0, sourceHeight > 0 else { throw SpaceError.invalidInput }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        for maxDimension in [1600, 1280, 1024, 800] {
            let scale = min(1, Double(maxDimension) / Double(max(sourceWidth, sourceHeight)))
            let width = max(1, Int(Double(sourceWidth) * scale))
            let height = max(1, Int(Double(sourceHeight) * scale))
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            for quality in [0.8, 0.65, 0.5] {
                let jpeg = renderer.jpegData(withCompressionQuality: quality) { _ in
                    image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                if jpeg.count <= 2_000_000 { return (jpeg, width, height) }
            }
        }
        throw SpaceError.capacity
    }
}
#endif
