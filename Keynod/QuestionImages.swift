import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures Claude mentioned, made small enough to travel with a question to the phone:
/// JPEG, at most 1600 px on the long side and 1.5 MB. Image data is never logged.
enum QuestionImages {
    static let maxSourceBytes = 20 * 1024 * 1024
    static let maxLongSide = 1600
    static let maxOutputBytes = 1_500_000
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]

    /// JPEGs for the readable image files among `paths` (absolute; at most `limit`).
    static func jpegs(paths: [String], limit: Int = 4) -> [Data] {
        var result: [Data] = []
        let cap = min(max(limit, 1), Link.maxImages)
        for path in paths {
            if result.count == cap { break }
            guard path.hasPrefix("/"), extensions.contains((path as NSString).pathExtension.lowercased()),
                  let data = read(path), let jpeg = jpeg(from: data) else { continue }
            result.append(jpeg)
        }
        return result
    }

    private static func read(_ path: String) -> Data? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0,
              info.st_size <= maxSourceBytes else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }

    /// The first frame of `data`, scaled down, flattened onto white, as a JPEG within the size limit.
    static func jpeg(
        from data: Data,
        maxLongSide: Int = maxLongSide,
        maxBytes: Int = maxOutputBytes,
        qualities: [Double] = [0.8, 0.65, 0.5, 0.35]
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var side = maxLongSide
        while side >= 400 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let flat = flattened(image) else { return nil }
            for quality in qualities {
                if let out = encode(flat, quality: quality), out.count <= maxBytes { return out }
            }
            side = side * 3 / 4
        }
        return nil
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
