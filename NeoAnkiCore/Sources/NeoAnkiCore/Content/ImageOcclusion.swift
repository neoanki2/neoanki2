import Foundation

public enum ImageOcclusionMode: String, Codable, CaseIterable, Sendable {
    case hideAllRevealOne
    case hideOneRevealOne
}

/// Coordinates in the oriented image, with origin at its top-left corner.
public struct OcclusionRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }

    /// Rectangle difference makes overlapping answers fully visible without
    /// uncovering the rest of another group's mask.
    public func subtracting(_ other: Self) -> [Self] {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(x + width, other.x + other.width)
        let bottom = min(y + height, other.y + other.height)
        guard left < right, top < bottom else { return [self] }
        return [
            Self(x: x, y: y, width: width, height: top - y),
            Self(x: x, y: bottom, width: width, height: y + height - bottom),
            Self(x: x, y: top, width: left - x, height: bottom - top),
            Self(x: right, y: top, width: x + width - right, height: bottom - top),
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}

public struct ImageOcclusionMask: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var group: Int
    public var rect: OcclusionRect
    public var answerText: String?

    public init(id: UUID = UUID(), group: Int, rect: OcclusionRect, answerText: String? = nil) {
        self.id = id; self.group = group; self.rect = rect; self.answerText = answerText
    }

    private enum CodingKeys: String, CodingKey { case id, group, rect, answerText }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(group, forKey: .group)
        try values.encode(rect, forKey: .rect)
        try values.encodeIfPresent(answerText, forKey: .answerText)
    }
}

public struct ImageOcclusionContent: Codable, Equatable, Sendable {
    public var image: MediaRef
    public var mode: ImageOcclusionMode
    public var masks: [ImageOcclusionMask]
    /// Never reuse a retired group's scheduling coordinate, even after an
    /// image replacement or removing every mask.
    public var nextGroup: Int

    public init(image: MediaRef, mode: ImageOcclusionMode = .hideAllRevealOne,
                masks: [ImageOcclusionMask] = [], nextGroup: Int = 1) {
        self.image = image; self.mode = mode; self.masks = masks; self.nextGroup = nextGroup
    }

    public var groups: [Int] { Set(masks.map(\.group)).sorted() }

    /// Reading previews may choose the first group. Study must never substitute
    /// a group when a persisted card's scheduling coordinate is missing.
    public func displayGroup(cardGroup: Int?, allowsPreview: Bool) -> Int? {
        if let cardGroup { return groups.contains(cardGroup) ? cardGroup : nil }
        return allowsPreview ? groups.first : nil
    }

    public mutating func addMask(rect: OcclusionRect) {
        guard rect.isValid, nextGroup > 0, nextGroup < Int.max else { return }
        masks.append(.init(group: nextGroup, rect: rect))
        nextGroup += 1
    }

    public mutating func ungroup(maskIDs: Set<UUID>) {
        for index in masks.indices where maskIDs.contains(masks[index].id) {
            guard nextGroup < Int.max else { return }
            masks[index].group = nextGroup
            nextGroup += 1
        }
    }

    public func coveredRects(group: Int, revealed: Bool) -> [OcclusionRect] {
        let active = masks.filter { $0.group == group }
        guard !active.isEmpty else { return masks.map(\.rect) }
        if mode == .hideOneRevealOne { return revealed ? [] : active.map(\.rect) }
        if !revealed { return masks.map(\.rect) }
        return masks.filter { $0.group != group }.flatMap { mask in
            active.reduce([mask.rect]) { pieces, target in
                pieces.flatMap { $0.subtracting(target.rect) }
            }
        }
    }

    public func revealedAnswerText(group: Int, revealed: Bool) -> String {
        guard revealed else { return "" }
        return masks.filter { $0.group == group }.compactMap(\.answerText).joined(separator: "; ")
    }
}

public enum ImageOcclusionValidation {
    public static func validateTransition(from previous: ImageOcclusionContent, to updated: ImageOcclusionContent) throws {
        let retainedGroups = Set(previous.groups)
        guard updated.nextGroup >= previous.nextGroup,
              updated.groups.allSatisfy({ retainedGroups.contains($0) || $0 >= previous.nextGroup }) else {
            throw DatabaseError.invalidItem("Occlusion groups cannot reuse retired numbers or decrease the group allocator.")
        }
        if previous.image.assetHash != updated.image.assetHash,
           !retainedGroups.isDisjoint(with: updated.groups) {
            throw DatabaseError.invalidItem("Replacing an occlusion image requires fresh groups.")
        }
    }

    public static func validate(_ content: ImageOcclusionContent) throws {
        guard content.image.kind == .image, content.image.isValidStoredReference else {
            throw DatabaseError.invalidItem("Image occlusion requires a valid still image.")
        }
        guard !(content.image.altText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseError.invalidItem("Add an image description that does not give away the answers.")
        }
        guard !content.masks.isEmpty,
              Set(content.masks.map(\.id)).count == content.masks.count,
              content.masks.allSatisfy({ $0.group > 0 && $0.rect.isValid }),
              content.nextGroup > (content.groups.last ?? 0), content.nextGroup < Int.max else {
            throw DatabaseError.invalidItem("Draw valid masks with unique IDs and a valid next group.")
        }
    }
}

public extension ContentValue {
    /// Every media consumer uses this accessor, including nested image values.
    var mediaReference: MediaRef? {
        switch self {
        case let .media(ref): ref
        case let .imageOcclusion(content): content.image
        default: nil
        }
    }

    func replacingMediaReference(_ reference: MediaRef) -> ContentValue {
        switch self {
        case .media: return .media(reference)
        case var .imageOcclusion(content):
            content.image = reference
            return .imageOcclusion(content)
        default: return self
        }
    }
}
