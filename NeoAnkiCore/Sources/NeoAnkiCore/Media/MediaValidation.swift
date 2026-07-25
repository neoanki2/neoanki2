import Foundation

public enum MediaError: Error, Sendable, Equatable, LocalizedError {
    case fileTooLarge(MediaKind, maxBytes: Int)
    case unsupportedFormat(MediaKind)
    case invalidPath
    case readFailed
    case sandboxViolation

    public var errorDescription: String? {
        switch self {
        case let .fileTooLarge(kind, maxBytes):
            return "\(kind.rawValue) files must be \(maxBytes / 1_000_000) MB or smaller."
        case let .unsupportedFormat(kind):
            return "This file is not a supported \(kind.rawValue) format."
        case .invalidPath:
            return "The media file path is invalid."
        case .readFailed:
            return "Could not read the media file."
        case .sandboxViolation:
            return "Media must stay inside the app storage area."
        }
    }
}

public enum MediaValidation {
    public static func maxBytes(for kind: MediaKind) -> Int {
        switch kind {
        case .audio: 20_000_000
        case .image: 10_000_000
        case .gif: 15_000_000
        case .video: 100_000_000
        }
    }

    public static func allowedExtensions(for kind: MediaKind) -> Set<String> {
        switch kind {
        case .audio: ["m4a", "mp3", "wav", "aac", "caf"]
        case .image: ["png", "jpg", "jpeg", "heic", "webp", "tiff"]
        case .gif: ["gif"]
        case .video: ["mp4", "mov", "m4v"]
        }
    }

    public static func defaultExtension(for kind: MediaKind) -> String {
        switch kind {
        case .audio: "m4a"
        case .image: "png"
        case .gif: "gif"
        case .video: "mp4"
        }
    }

    public static func validate(data: Data, kind: MediaKind, fileExtension: String) throws {
        guard data.count <= maxBytes(for: kind) else {
            throw MediaError.fileTooLarge(kind, maxBytes: maxBytes(for: kind))
        }

        let ext = fileExtension.lowercased()
        guard allowedExtensions(for: kind).contains(ext) else {
            throw MediaError.unsupportedFormat(kind)
        }

        guard matchesMagicBytes(data, kind: kind, fileExtension: ext) else {
            throw MediaError.unsupportedFormat(kind)
        }
    }

    /// Validates bytes, declared media kind, and filename extension together,
    /// then returns the safe extension used for content-addressed storage.
    public static func validatedExtension(
        data: Data,
        kind: MediaKind,
        fileExtension: String
    ) throws -> String {
        try validate(data: data, kind: kind, fileExtension: fileExtension)
        return canonicalExtension(fileExtension.lowercased())
    }

    private static func canonicalExtension(_ fileExtension: String) -> String {
        fileExtension == "jpeg" ? "jpg" : fileExtension
    }

    private static func matchesMagicBytes(
        _ data: Data,
        kind: MediaKind,
        fileExtension: String
    ) -> Bool {
        guard !data.isEmpty else { return false }
        let bytes = [UInt8](data.prefix(64))

        switch (kind, fileExtension) {
        case (.audio, "mp3"):
            return hasPrefix(bytes, ascii: "ID3") || isMPEG1LayerAudio(bytes)
        case (.audio, "wav"):
            return hasPrefix(bytes, ascii: "RIFF") && hasBytes(bytes, ascii: "WAVE", at: 8)
        case (.audio, "aac"):
            return isADTS(bytes)
        case (.audio, "caf"):
            return hasPrefix(bytes, ascii: "caff")
        case (.audio, "m4a"):
            return isISOBaseMedia(bytes, brands: ["M4A ", "M4B "])
        case (.image, "png"):
            return hasPrefix(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case (.image, "jpg"), (.image, "jpeg"):
            return hasPrefix(bytes, [0xFF, 0xD8, 0xFF])
        case (.image, "heic"):
            return isISOBaseMedia(
                bytes,
                brands: ["heic", "heix", "hevc", "hevx", "mif1", "msf1"]
            )
        case (.image, "webp"):
            return hasPrefix(bytes, ascii: "RIFF") && hasBytes(bytes, ascii: "WEBP", at: 8)
        case (.image, "tiff"):
            return hasPrefix(bytes, [0x49, 0x49, 0x2A, 0x00])
                || hasPrefix(bytes, [0x4D, 0x4D, 0x00, 0x2A])
        case (.gif, "gif"):
            return hasPrefix(bytes, ascii: "GIF87a") || hasPrefix(bytes, ascii: "GIF89a")
        case (.video, "mov"):
            return isISOBaseMedia(bytes, brands: ["qt  "])
        case (.video, "m4v"):
            return isISOBaseMedia(bytes, brands: ["M4V ", "M4VH", "M4VP"])
        case (.video, "mp4"):
            return isISOBaseMedia(
                bytes,
                brands: ["isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "dash"]
            )
        default:
            return false
        }
    }

    private static func isMPEG1LayerAudio(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        return bytes[0] == 0xFF
            && bytes[1] & 0xE0 == 0xE0
            && bytes[1] & 0x06 != 0
    }

    private static func isADTS(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        return bytes[0] == 0xFF && bytes[1] & 0xF6 == 0xF0
    }

    private static func isISOBaseMedia(_ bytes: [UInt8], brands: Set<String>) -> Bool {
        guard hasBytes(bytes, ascii: "ftyp", at: 4), bytes.count >= 12 else {
            return false
        }

        if let majorBrand = asciiString(bytes, at: 8), brands.contains(majorBrand) {
            return true
        }

        var offset = 16
        while offset + 4 <= bytes.count {
            if let brand = asciiString(bytes, at: offset), brands.contains(brand) {
                return true
            }
            offset += 4
        }
        return false
    }

    private static func hasPrefix(_ data: [UInt8], ascii: String) -> Bool {
        hasPrefix(data, Array(ascii.utf8))
    }

    private static func hasBytes(_ data: [UInt8], ascii: String, at offset: Int) -> Bool {
        let expected = Array(ascii.utf8)
        guard offset >= 0, data.count >= offset + expected.count else { return false }
        return data[offset ..< offset + expected.count].elementsEqual(expected)
    }

    private static func asciiString(_ data: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        return String(bytes: data[offset ..< offset + 4], encoding: .ascii)
    }

    private static func hasPrefix(_ data: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard data.count >= prefix.count else { return false }
        return zip(data, prefix).allSatisfy { $0 == $1 }
    }
}
