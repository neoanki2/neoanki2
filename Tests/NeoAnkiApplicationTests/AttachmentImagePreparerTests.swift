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
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let image: CGImage
    if noise {
        var pixels = Data(repeating: alpha ? 128 : 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var random: UInt64 = 42
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                random = random &* 6364136223846793005 &+ 1
                bytes[offset] = UInt8(truncatingIfNeeded: random >> 32)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: random >> 40)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: random >> 48)
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    } else {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(red: 180.0 / 255, green: 90.0 / 255, blue: 40.0 / 255, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        image = try #require(context.makeImage())
    }
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private source metadata"],
    ]
    if type == .tiff {
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 1]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
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
    // An uncompressed TIFF exceeds the byte limit without spending time
    // encoding noise. The fixture stays below the independent pixel limit.
    let original = try attachmentFixture(width: 2300, height: 1600, type: .tiff)
    try #require(original.count > MediaValidation.maxBytes(for: .image))
    let originalEXIF = try attachmentProperties(original)[kCGImagePropertyExifDictionary] as? [CFString: Any]
    try #require(originalEXIF?[kCGImagePropertyExifUserComment] as? String == "Private source metadata")
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
    let sourceWidth = 5_000, sourceHeight = 400
    let original = try attachmentFixture(width: sourceWidth, height: sourceHeight, alpha: true)
    let result = try await AttachmentImagePreparer.prepare(data: original)
    #expect(result.fileExtension == "png")
    let properties = try attachmentProperties(result.data)
    let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    #expect(width == 4096)
    let scaledHeight = Double(width) * Double(sourceHeight) / Double(sourceWidth)
    #expect(abs(Double(height) - scaledHeight) <= 1)
    let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
}

@Test func oversizedTransparentNoiseReducesDimensionsUntilPNGSizeFits() async throws {
    let original = try attachmentFixture(width: 2100, height: 1700, alpha: true, noise: true)
    try #require(original.count > MediaValidation.maxBytes(for: .image))
    let result = try await AttachmentImagePreparer.prepare(data: original)
    #expect(result.fileExtension == "png")
    #expect(result.data.count <= MediaValidation.maxBytes(for: .image))
    #expect(try attachmentProperties(result.data)[kCGImagePropertyPixelWidth] as? Int ?? 0 < 2100)
}

@Test(arguments: [UTType.jpeg, .heic])
func largeRotatedPhotoBakesInOrientation(type: UTType) async throws {
    let sourceWidth = 5_000, sourceHeight = 400
    let original = try attachmentFixture(width: sourceWidth, height: sourceHeight, type: type, orientation: 6)
    let result = try await AttachmentImagePreparer.prepare(data: original)
    let properties = try attachmentProperties(result.data)
    let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    #expect(height == 4096)
    let scaledWidth = Double(height) * Double(sourceHeight) / Double(sourceWidth)
    #expect(abs(Double(width) - scaledWidth) <= 1)
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
