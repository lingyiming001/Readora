import UIKit
import ImageIO

/// Decode bounded thumbnails rather than allocating full-size ebook illustrations.
@MainActor
func mobileThumbnail(_ data: Data, maxPixel: Int) async -> UIImage? {
    let image = await Task.detached(priority: .utility) { () -> CGImage? in
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }.value
    guard !Task.isCancelled, let image else { return nil }
    return UIImage(cgImage: image)
}
