#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

private let windowCornerRadius: CGFloat = 25

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func hasTransparentWindowCorners(_ image: CGImage) -> Bool {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return false
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    func alpha(x: Int, y: Int) -> UInt8 {
        pixels[((y * width + x) * 4) + 3]
    }
    return [
        alpha(x: 0, y: 0),
        alpha(x: width - 1, y: 0),
        alpha(x: 0, y: height - 1),
        alpha(x: width - 1, y: height - 1),
    ].allSatisfy { $0 == 0 }
}

private func normalizedImage(_ image: CGImage) -> CGImage? {
    guard image.width >= Int(windowCornerRadius * 2),
          image.height >= Int(windowCornerRadius * 2) else {
        return nil
    }

    let width = image.width
    let height = image.height
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.clear(bounds)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .none
    context.addPath(
        CGPath(
            roundedRect: bounds,
            cornerWidth: windowCornerRadius,
            cornerHeight: windowCornerRadius,
            transform: nil
        )
    )
    context.clip()
    context.draw(image, in: bounds)
    return context.makeImage()
}

private func pngData(for image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        "public.png" as CFString,
        1,
        nil
    ) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fail("Usage: normalize-doc-screenshot-corners.swift <directory> <filename> ...")
}

let directory = URL(fileURLWithPath: arguments[0], isDirectory: true)
var normalizedCount = 0
for filename in arguments.dropFirst() {
    guard filename == URL(fileURLWithPath: filename).lastPathComponent else {
        fail("Screenshot filename must not contain a path: \(filename)")
    }
    let url = directory.appendingPathComponent(filename)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("Could not read documentation screenshot: \(url.path)")
    }
    if hasTransparentWindowCorners(sourceImage) { continue }
    guard let image = normalizedImage(sourceImage), let data = pngData(for: image) else {
        fail("Could not normalize documentation screenshot: \(url.path)")
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("Could not write normalized documentation screenshot \(url.path): \(error)")
    }
    normalizedCount += 1
}

print(
    "Normalized \(normalizedCount) documentation screenshots with transparent window corners"
)
