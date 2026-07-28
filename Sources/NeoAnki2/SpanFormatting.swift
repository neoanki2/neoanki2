import AppKit
import NeoAnkiCore
import SwiftUI

enum SpanFormatting {
    static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: DesignSystem.Typography.richTextFont,
            .foregroundColor: NSColor.textColor,
        ]
    }

    static func attributedString(
        from spans: [Span],
        pointSize: CGFloat = DesignSystem.Typography.richTextPointSize
    ) -> NSAttributedString {
        spans.reduce(into: NSMutableAttributedString()) { result, span in
            result.append(NSAttributedString(string: span.text, attributes: attributes(for: span, pointSize: pointSize)))
        }
    }

    static func swiftUIAttributedString(
        from spans: [Span],
        pointSize: CGFloat = DesignSystem.Typography.richTextPointSize
    ) -> AttributedString {
        AttributedString(attributedString(from: spans, pointSize: pointSize))
    }

    static func spans(from attributedString: NSAttributedString) -> [Span] {
        guard attributedString.length > 0 else { return [] }

        var spans: [Span] = []
        let fullRange = NSRange(location: 0, length: attributedString.length)

        attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            // Inline attachments are outside NeoAnki's portable rich-text model.
            guard attributes[.attachment] == nil else { return }
            let text = attributedString.attributedSubstring(from: range).string
            guard !text.isEmpty else { return }
            spans.append(Span(
                text,
                styles: styles(from: attributes),
                textColor: textColor(from: attributes),
                textSize: textSize(from: attributes),
                link: link(from: attributes)
            ))
        }

        return mergeAdjacent(spans)
    }

    static func plainText(from spans: [Span]) -> String {
        spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mergeAdjacent(_ spans: [Span]) -> [Span] {
        spans.reduce(into: [Span]()) { result, span in
            guard !span.text.isEmpty else { return }
            if let last = result.last, last.hasSameFormatting(as: span) {
                result[result.count - 1] = Span(
                    last.text + span.text,
                    styles: last.styles,
                    textColor: last.textColor,
                    textSize: last.textSize,
                    link: last.link
                )
            } else {
                result.append(span)
            }
        }
    }

    /// Compact span summary exposed on text views during UI testing.
    static func testingDescription(from spans: [Span]) -> String {
        mergeAdjacent(spans).map { span in
            if !span.hasFormatting {
                return "plain:\(span.text)"
            }
            var formatting = span.styles.map(\.rawValue).sorted()
            if let textColor = span.textColor {
                formatting.append("color-\(textColor.rawValue)")
            }
            if let textSize = span.textSize {
                formatting.append("size-\(textSize.rawValue)")
            }
            if span.link != nil {
                formatting.append("link")
            }
            return "\(formatting.joined(separator: "+")):\(span.text)"
        }.joined(separator: "|")
    }

    private static func attributes(for span: Span, pointSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let resolvedPointSize = pointSize * sizeMultiplier(for: span.textSize)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: span, pointSize: resolvedPointSize),
            .foregroundColor: span.textColor.map(nsColor(for:)) ?? NSColor.textColor,
        ]

        if span.styles.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if span.styles.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if span.styles.contains(.highlight) {
            attributes[.backgroundColor] = NSColor.findHighlightColor
        } else if span.styles.contains(.code) {
            attributes[.backgroundColor] = NSColor.controlBackgroundColor
        }
        if span.styles.contains(.superscript) {
            attributes[.superscript] = 1
        } else if span.styles.contains(.subscriptText) {
            attributes[.superscript] = -1
        }
        if let link = span.link,
           RichTextValidation.isValidLink(link),
           let url = URL(string: link) {
            attributes[.link] = url
            if span.textColor == nil {
                attributes[.foregroundColor] = NSColor.linkColor
            }
        }

        return attributes
    }

    private static let adaptiveTextColors: [Span.TextColor: NSColor] = {
        Dictionary(uniqueKeysWithValues: Span.TextColor.allCases.map { color in
            let systemColor: NSColor = switch color {
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .mint: .systemMint
            case .teal: .systemTeal
            case .cyan: .systemCyan
            case .blue: .systemBlue
            case .indigo: .systemIndigo
            case .purple: .systemPurple
            case .pink: .systemPink
            case .brown: .systemBrown
            case .gray: .systemGray
            }
            return (color, contrastSafeTextColor(from: systemColor))
        })
    }()

    static func nsColor(for color: Span.TextColor) -> NSColor {
        adaptiveTextColors[color] ?? .textColor
    }

    private static func contrastSafeTextColor(from systemColor: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var base = systemColor
            var background = NSColor.textBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                base = systemColor.usingColorSpace(.sRGB) ?? systemColor
                background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
                    ?? .textBackgroundColor
            }
            guard contrastRatio(base, background) < 4.5 else { return base }

            let black = NSColor.black
            let white = NSColor.white
            let target = contrastRatio(black, background) >= contrastRatio(white, background)
                ? black
                : white
            for step in 1...20 {
                let fraction = CGFloat(step) / 20
                if let candidate = base.blended(withFraction: fraction, of: target),
                   contrastRatio(candidate, background) >= 4.5 {
                    return candidate
                }
            }
            return target
        }
    }

    private static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    static func sizeMultiplier(for size: Span.TextSize?) -> CGFloat {
        switch size {
        case .small: 0.85
        case .large: 1.25
        case nil: 1
        }
    }

    private static func font(for span: Span, pointSize: CGFloat) -> NSFont {
        let size = pointSize
        if span.styles.contains(.code) {
            var font = NSFont.monospacedSystemFont(
                ofSize: size,
                weight: span.styles.contains(.bold) ? .bold : .regular
            )
            if span.styles.contains(.italic) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return font
        }

        var font = NSFont.systemFont(
            ofSize: size,
            weight: span.styles.contains(.bold) ? .bold : .regular
        )
        if span.styles.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func styles(from attributes: [NSAttributedString.Key: Any]) -> Set<Span.Style> {
        var styles: Set<Span.Style> = []

        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) {
                styles.insert(.bold)
            }
            if traits.contains(.italic) {
                styles.insert(.italic)
            }
            if font.isFixedPitch {
                styles.insert(.code)
            }
        }

        if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
            styles.insert(.underline)
        }
        if let strikethrough = attributes[.strikethroughStyle] as? Int, strikethrough != 0 {
            styles.insert(.strikethrough)
        }

        if let background = attributes[.backgroundColor] as? NSColor {
            if background.isEqual(NSColor.findHighlightColor) {
                styles.insert(.highlight)
            } else if background.isEqual(NSColor.controlBackgroundColor) {
                styles.insert(.code)
            }
        }
        if let superscript = (attributes[.superscript] as? NSNumber)?.intValue {
            if superscript > 0 {
                styles.insert(.superscript)
            } else if superscript < 0 {
                styles.insert(.subscriptText)
            }
        } else if let superscript = attributes[.superscript] as? Int {
            if superscript > 0 {
                styles.insert(.superscript)
            } else if superscript < 0 {
                styles.insert(.subscriptText)
            }
        }

        return styles
    }

    private static func textColor(
        from attributes: [NSAttributedString.Key: Any]
    ) -> Span.TextColor? {
        guard let color = attributes[.foregroundColor] as? NSColor else { return nil }
        return Span.TextColor.allCases.first { color.isEqual(nsColor(for: $0)) }
    }

    private static func textSize(
        from attributes: [NSAttributedString.Key: Any]
    ) -> Span.TextSize? {
        guard let font = attributes[.font] as? NSFont else { return nil }
        let ratio = font.pointSize / DesignSystem.Typography.richTextPointSize
        if ratio < 0.925 {
            return .small
        }
        if ratio > 1.125 {
            return .large
        }
        return nil
    }

    private static func link(
        from attributes: [NSAttributedString.Key: Any]
    ) -> String? {
        let value: String?
        if let url = attributes[.link] as? URL {
            value = url.absoluteString
        } else {
            value = attributes[.link] as? String
        }
        guard let value, RichTextValidation.isValidLink(value) else { return nil }
        return value
    }
}
