import CoreGraphics
import Foundation
import ImageIO
import NeoAnkiApplication
import NeoAnkiCore
import Testing
import UniformTypeIdentifiers

@Suite struct AttachmentImagePreparerTests {

private func attachmentFixture(width: Int, height: Int, alpha: Bool = false,
                               noise: Bool = false, type: UTType = .png,
                               orientation: Int = 1) throws -> Data {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var random: UInt64 = 42
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        random = random &* 6364136223846793005 &+ 1
        pixels[offset] = noise ? UInt8(truncatingIfNeeded: random >> 32) : 180
        pixels[offset + 1] = noise ? UInt8(truncatingIfNeeded: random >> 40) : 90
        pixels[offset + 2] = noise ? UInt8(truncatingIfNeeded: random >> 48) : 40
        pixels[offset + 3] = alpha ? 128 : 255
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private source metadata"]] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func attachmentProperties(_ data: Data) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

@Test func smallImagesKeepTheirOriginalBytesAndInferFormatFromContents() async throws {
    let original = try attachmentFixture(width: 80, height: 40)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("wrong.avif")
    try original.write(to: file)
    let result = try await AttachmentImagePreparer.prepare(url: file)
    #expect(result.data == original)
    #expect(result.fileExtension == "png")
}

@Test func oversizedOpaquePhotoIsCompressedUnderTheStorageLimit() async throws {
    let original = try attachmentFixture(width: 2300, height: 1600, noise: true)
    #expect(original.count > MediaValidation.maxBytes(for: .image))
    let result = try await AttachmentImagePreparer.prepare(data: original)
    #expect(result.fileExtension == "jpg")
    #expect(result.data.count <= MediaValidation.maxBytes(for: .image))
    try MediaValidation.validate(data: result.data, kind: .image, fileExtension: result.fileExtension)
    let properties = try attachmentProperties(result.data)
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2300)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1600)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifUserComment] == nil)
}

@Test func largeTransparentDiagramKeepsAlphaAndAspectRatio() async throws {
    let original = try attachmentFixture(width: 5000, height: 1000, alpha: true)
    let result = try await AttachmentImagePreparer.prepare(data: original)
    #expect(result.fileExtension == "png")
    let properties = try attachmentProperties(result.data)
    let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    #expect(width == 4096)
    #expect(abs(Double(width) / Double(height) - 5) < 0.01)
    let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
}

@Test func oversizedTransparentNoiseReducesDimensionsUntilPNGSizeFits() async throws {
    let original = try attachmentFixture(width: 2100, height: 1700, alpha: true, noise: true)
    #expect(original.count > MediaValidation.maxBytes(for: .image))
    let result = try await AttachmentImagePreparer.prepare(data: original)
    #expect(result.fileExtension == "png")
    #expect(result.data.count <= MediaValidation.maxBytes(for: .image))
    #expect(try attachmentProperties(result.data)[kCGImagePropertyPixelWidth] as? Int ?? 0 < 2100)
}

@Test(arguments: [UTType.jpeg, .heic])
func largeRotatedPhotoBakesInOrientation(type: UTType) async throws {
    let original = try attachmentFixture(width: 5000, height: 1000, type: type, orientation: 6)
    let result = try await AttachmentImagePreparer.prepare(data: original)
    let properties = try attachmentProperties(result.data)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 4096)
    #expect(properties[kCGImagePropertyPixelWidth] as? Int ?? 0 < 1000)
    #expect(properties[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
}

@Test func AVIFConvertsToAStorageSupportedFormatWhenDecoderAvailable() async throws {
    guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.avif") == true else { return }
    let original = try attachmentFixture(width: 80, height: 40, type: UTType("public.avif")!)
    let result = try await AttachmentImagePreparer.prepare(data: original)
    #expect(result.fileExtension == "jpg")
    try MediaValidation.validate(data: result.data, kind: .image, fileExtension: result.fileExtension)
}

@Test func webPImageIsDecodedAndPreserved() async throws {
    // A real 1 × 1 VP8 WebP, including its RIFF container.
    let original = try #require(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
    let result = try await AttachmentImagePreparer.prepare(data: original)
    #expect(result.fileExtension == "webp")
    #expect(result.data == original)
}

@Test func invalidImagesAndNonFileURLsAreRejected() async throws {
    await #expect(throws: MediaError.unsupportedFormat(.image)) {
        try await AttachmentImagePreparer.prepare(data: Data("not an image".utf8))
    }
    await #expect(throws: MediaError.invalidPath) {
        try await AttachmentImagePreparer.prepare(url: URL(string: "https://example.com/photo.png")!)
    }
}

@Test func canceledPreparationDoesNotReturnAnAttachment() async throws {
    let original = try attachmentFixture(width: 50, height: 50)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AttachmentImagePreparer.prepare(data: original)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

}
