import AppKit
import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

// The loader's keying can be verified independently of NSCache's eviction policy.
private final class RetainedThumbnailCache: NSCache<NSString, NSImage> {
    private var images: [String: NSImage] = [:]

    override func object(forKey key: NSString) -> NSImage? {
        images[key as String]
    }

    override func setObject(_ image: NSImage, forKey key: NSString, cost: Int) {
        images[key as String] = image
    }
}

@Test @MainActor func mediaImageLoaderLoadsThumbnailOffTheRenderPath() async throws {
    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-thumbnail-\(UUID().uuidString).png")
    try png.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = await MediaImageLoader.shared.image(for: url, kind: .image, maxPixelSize: 64)

    #expect(image != nil)
    #expect(image?.size.width == 1)
    #expect(image?.size.height == 1)
}

@Test @MainActor func mediaImageLoaderReturnsNilForInvalidImage() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-invalid-image-\(UUID().uuidString).png")
    try Data("not an image".utf8).write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = await MediaImageLoader.shared.image(for: url, kind: .image, maxPixelSize: 64)

    #expect(image == nil)
}

@Test @MainActor func mediaImageLoaderCachesByURLKindAndPixelSize() async throws {
    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-cached-thumbnail-\(UUID().uuidString).png")
    try png.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let loader = MediaImageLoader(cache: RetainedThumbnailCache())
    let first = try #require(
        await loader.image(for: url, kind: .image, maxPixelSize: 64)
    )
    let cached = try #require(
        await loader.image(for: url, kind: .image, maxPixelSize: 64)
    )
    let otherSize = try #require(
        await loader.image(for: url, kind: .image, maxPixelSize: 128)
    )

    #expect(first === cached)
    #expect(first !== otherSize)
}

@Test @MainActor func mediaImageLoaderLoadsGIFData() async throws {
    let gif = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-animation-\(UUID().uuidString).gif")
    try gif.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = await MediaImageLoader.shared.image(for: url, kind: .gif, maxPixelSize: 64)

    #expect(image != nil)
}

@Test @MainActor func mediaImageLoaderReturnsNilForMissingFile() async {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-missing-\(UUID().uuidString).png")

    let image = await MediaImageLoader.shared.image(for: url, kind: .image, maxPixelSize: 64)

    #expect(image == nil)
}
