#if os(iOS) && DEBUG
import Foundation
import ImageIO
import NeoAnkiCore
import UIKit
import UniformTypeIdentifiers

/// Seeds only the disposable UI test app's Simulator clipboard.
@MainActor enum MobileImageAttachmentUITestFixture {
    static func seedIfRequested() throws {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-NeoAnkiUITestingReset"),
              process.environment["NEOANKI_TEST_SCENARIO"] == "mobile-item-lookup",
              process.environment["NEOANKI_TEST_IMAGE_CLIPBOARD"] == "large" else { return }
        let data = try makeOversizedPNG()
        guard data.count > MediaValidation.maxBytes(for: .image) else { throw MediaError.readFailed }
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
    }

    private static func makeOversizedPNG() throws -> Data {
        let width = 2300, height = 1600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt64 = 42
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            random = random &* 6364136223846793005 &+ 1
            pixels[offset] = UInt8(truncatingIfNeeded: random >> 32)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: random >> 40)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: random >> 48)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw MediaError.readFailed }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw MediaError.readFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.readFailed }
        return encoded as Data
    }
}
#endif
