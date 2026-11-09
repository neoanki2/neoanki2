import Foundation
import ImageIO
import NeoAnkiCore
import UniformTypeIdentifiers

public struct PreparedAttachmentImage: Sendable {
    public let data: Data
    public let fileExtension: String
}

/// Interactive authoring only: storage and import contracts still validate original bytes.
public enum AttachmentImagePreparer {
    // A 4096-pixel edge retains diagram detail while bounding decoded working memory.
    public static let maximumPixelSize = 4096

    public static func prepare(data: Data) async throws -> PreparedAttachmentImage {
        try await run { try prepare(source: CGImageSourceCreateWithData(data as CFData, sourceOptions), original: { data }) }
    }

    public static func prepare(url: URL) async throws -> PreparedAttachmentImage {
        try await run {
            guard url.isFileURL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw MediaError.invalidPath
            }
            return try prepare(source: CGImageSourceCreateWithURL(url as CFURL, sourceOptions)) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= MediaValidation.maxBytes(for: .image) else { return nil }
                // Read only a bounded candidate for byte-preserving passthrough.
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: MediaValidation.maxBytes(for: .image) + 1)
            }
        }
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func run(
        _ operation: @escaping @Sendable () throws -> PreparedAttachmentImage
    ) async throws -> PreparedAttachmentImage {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    private static func hasTransparency(_ image: CGImage) -> Bool {
        guard ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return false }
        var alpha = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return alpha.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 255 }
        }
    }

    private static func prepare(
        source: CGImageSource?, original: () throws -> Data?
    ) throws -> PreparedAttachmentImage {
        try Task.checkCancellation()
        guard let source, CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw MediaError.unsupportedFormat(.image) }

        var edge = min(maximumPixelSize, max(width, height))
        while edge >= 1 {
            try Task.checkCancellation()
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw MediaError.unsupportedFormat(.image)
            }
            let sourceType = CGImageSourceGetType(source) as String? ?? ""
            let storableTypes: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff", "org.webmproject.webp"]
            if storableTypes.contains(sourceType), edge == min(maximumPixelSize, max(width, height)),
               max(width, height) <= maximumPixelSize, CGImageSourceGetCount(source) == 1,
               let data = try original(),
               let ext = try? MediaValidation.inferredExtension(data: data, expectedKind: .image) {
                return PreparedAttachmentImage(data: data, fileExtension: ext)
            }
            let transparent = hasTransparency(image)
            let ext = transparent ? "png" : "jpg"
            for quality in transparent ? [1.0] : [0.85, 0.75, 0.65] {
                try Task.checkCancellation()
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    encoded, (transparent ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil
                ) else { throw MediaError.readFailed }
                // Add the decoded bitmap, never the source's EXIF/GPS metadata.
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw MediaError.readFailed }
                let data = encoded as Data
                if data.count <= MediaValidation.maxBytes(for: .image) {
                    try MediaValidation.validate(data: data, kind: .image, fileExtension: ext)
                    return PreparedAttachmentImage(data: data, fileExtension: ext)
                }
            }
            if edge == 1 { break }
            edge = max(1, Int(Double(edge) * 0.75))
        }
        throw MediaError.fileTooLarge(.image, maxBytes: MediaValidation.maxBytes(for: .image))
    }
}
