import AppKit
import Foundation
import ImageIO
import NeoAnkiCore

@MainActor
final class MediaImageLoader {
    static let shared = MediaImageLoader()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 32
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func image(for url: URL, kind: MediaKind, maxPixelSize: Int) async -> NSImage? {
        let key = "\(url.path)|\(kind.rawValue)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let payload = await Task.detached(priority: .userInitiated) {
            Self.loadPayload(from: url, kind: kind, maxPixelSize: maxPixelSize)
        }.value
        guard let payload else { return nil }

        let image: NSImage
        let cost: Int
        switch payload {
        case let .thumbnail(cgImage):
            image = NSImage(cgImage: cgImage, size: .zero)
            cost = cgImage.bytesPerRow * cgImage.height
        case let .animated(data):
            guard let animatedImage = NSImage(data: data) else { return nil }
            image = animatedImage
            cost = data.count
        }
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    nonisolated private static func loadPayload(
        from url: URL,
        kind: MediaKind,
        maxPixelSize: Int
    ) -> LoadedImagePayload? {
        if kind == .gif {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
            return .animated(data)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return .thumbnail(image)
    }
}

private enum LoadedImagePayload: @unchecked Sendable {
    case thumbnail(CGImage)
    case animated(Data)
}
