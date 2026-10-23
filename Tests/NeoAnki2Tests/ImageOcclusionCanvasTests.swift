import CoreGraphics
import Foundation
import ImageIO
import NeoAnkiCore
import Testing
import UniformTypeIdentifiers
@testable import NeoAnkiSharedUI

@Test func occlusionCanvasNormalizesClampsAndKeepsZoomCoordinates() {
    let rect = normalizedOcclusionRect(from: .init(x: 20, y: 30), to: .init(x: 80, y: 90), in: .init(width: 100, height: 150))
    let zoomed = normalizedOcclusionRect(from: .init(x: 80, y: 120), to: .init(x: 320, y: 360), in: .init(width: 400, height: 600))
    #expect(rect == zoomed)
    let pixels = pixelRect(rect, in: .init(width: 400, height: 600))
    #expect(abs(pixels.minX - 80) < 0.000001 && abs(pixels.minY - 120) < 0.000001)
    #expect(abs(pixels.width - 240) < 0.000001 && abs(pixels.height - 240) < 0.000001)
    #expect(normalizedOcclusionRect(from: .init(x: -10, y: -30), to: .init(x: 200, y: 180), in: .init(width: 100, height: 150)) == .init(x: 0, y: 0, width: 1, height: 1))
    #expect(!normalizedOcclusionRect(from: .zero, to: .zero, in: .init(width: 100, height: 150)).isValid)
}

@Test func occlusionBitmapUsesOrientedPortraitAndLandscapeImagesAndFailsClosed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 120, height: 80))
    let image = try #require(context.makeImage())
    for (orientation, width, height) in [(1, 120, 80), (6, 80, 120), (8, 80, 120)] {
        let url = directory.appendingPathComponent("orientation-\(orientation).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let loaded = try #require(OcclusionBitmap.load(url: url))
        #expect(loaded.image.width == width)
        #expect(loaded.image.height == height)
    }
    #expect(OcclusionBitmap.load(url: directory.appendingPathComponent("missing.jpg")) == nil)
}
