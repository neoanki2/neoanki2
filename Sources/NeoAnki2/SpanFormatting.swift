import AppKit
import NeoAnkiCore
import SwiftUI

enum SpanFormatting {
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
            let text = attributedString.attributedSubstring(from: range).string
            guard !text.isEmpty else { return }
            spans.append(Span(text, styles: styles(from: attributes)))
        }

        return mergeAdjacent(spans)
    }

    static func plainText(from spans: [Span]) -> String {
        spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mergeAdjacent(_ spans: [Span]) -> [Span] {
        spans.reduce(into: [Span]()) { result, span in
            guard !span.text.isEmpty else { return }
            if let last = result.last, last.styles == span.styles {
                result[result.count - 1] = Span(last.text + span.text, styles: last.styles)
            } else {
                result.append(span)
            }
        }
    }

    /// Compact span summary exposed on text views during UI testing.
    static func testingDescription(from spans: [Span]) -> String {
        mergeAdjacent(spans).map { span in
            if span.styles.isEmpty {
                return "plain:\(span.text)"
            }
            let styleNames = span.styles.map(\.rawValue).sorted().joined(separator: "+")
            return "\(styleNames):\(span.text)"
        }.joined(separator: "|")
    }

    private static func attributes(for span: Span, pointSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(for: span, pointSize: pointSize)]

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

        return attributes
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

        return styles
    }
}
