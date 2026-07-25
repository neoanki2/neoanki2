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

        guard matchesMagicBytes(data, kind: kind) else {
            throw MediaError.unsupportedFormat(kind)
        }
    }

    private static func matchesMagicBytes(_ data: Data, kind: MediaKind) -> Bool {
        guard !data.isEmpty else { return false }
        let bytes = [UInt8](data.prefix(12))

        switch kind {
        case .audio:
            return hasPrefix(bytes, [0xFF, 0xFB])
                || hasPrefix(bytes, [0x49, 0x44, 0x33])
                || hasPrefix(bytes, [0x52, 0x49, 0x46, 0x46])
                || hasPrefix(bytes, [0x66, 0x74, 0x79, 0x70])
                || hasPrefix(bytes, [0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70])
        case .image:
            return hasPrefix(bytes, [0x89, 0x50, 0x4E, 0x47])
                || hasPrefix(bytes, [0xFF, 0xD8, 0xFF])
                || hasPrefix(bytes, [0x47, 0x49, 0x46, 0x38])
                || hasPrefix(bytes, [0x52, 0x49, 0x46, 0x46])
        case .gif:
            return hasPrefix(bytes, [0x47, 0x49, 0x46, 0x38])
        case .video:
            return hasPrefix(bytes, [0x00, 0x00, 0x00])
                || hasPrefix(bytes, [0x66, 0x74, 0x79, 0x70])
                || hasPrefix(bytes, [0x00, 0x00, 0x01, 0xBA])
        }
    }

    private static func hasPrefix(_ data: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard data.count >= prefix.count else { return false }
        return zip(data, prefix).allSatisfy { $0 == $1 }
    }
}
