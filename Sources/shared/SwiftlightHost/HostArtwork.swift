import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Validate encoded covers without retaining a full-resolution decoded image.
/// Byte, frame-count and pixel bounds are checked before requesting a thumbnail.
enum HostArtwork {
    static let maximumDimension = 4096
    static let maximumPixelCount = 8 * 1024 * 1024

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= HostHTTPRequest.maximumResponseBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              width <= maximumPixelCount / height else { throw HostError.invalidArtwork }

        // Metadata alone also accepts damaged/truncated compressed payloads. Ask
        // ImageIO for a tiny decoded image before returning bytes to a UI cache.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw HostError.invalidArtwork }
    }
}
