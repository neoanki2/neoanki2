#if os(iOS)
import NeoAnkiCore
import SwiftUI
import UIKit

struct RichSpanTextEditor: UIViewRepresentable {
    @Binding var spans: [Span]

    func makeCoordinator() -> Coordinator { Coordinator(spans: $spans) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 10
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.accessibilityLabel = "Rich text"
        view.attributedText = Self.attributed(spans)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard !context.coordinator.isPublishing else { return }
        let incoming = spans.map(\.text).joined()
        if view.text != incoming { view.attributedText = Self.attributed(spans) }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var spans: [Span]
        var isPublishing = false
        init(spans: Binding<[Span]>) { _spans = spans }
        func textViewDidChange(_ textView: UITextView) {
            isPublishing = true
            spans = RichSpanTextEditor.spans(from: textView.attributedText)
            isPublishing = false
        }
    }

    private static func attributed(_ spans: [Span]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in spans {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if span.styles.contains(.bold) { traits.insert(.traitBold) }
            if span.styles.contains(.italic) { traits.insert(.traitItalic) }
            let base = UIFont.preferredFont(forTextStyle: span.textSize == .large ? .title3 : span.textSize == .small ? .footnote : .body)
            let font = base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: 0) } ?? base
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(span.textColor)]
            if span.styles.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if span.styles.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if span.styles.contains(.highlight) { attributes[.backgroundColor] = UIColor.systemYellow.withAlphaComponent(0.3) }
            if span.styles.contains(.superscript) { attributes[.baselineOffset] = 5 }
            if span.styles.contains(.subscriptText) { attributes[.baselineOffset] = -3 }
            if let link = span.link, let url = URL(string: link) { attributes[.link] = url }
            result.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return result
    }

    private static func spans(from value: NSAttributedString) -> [Span] {
        guard value.length > 0 else { return [] }
        var output: [Span] = []
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            let text = (value.string as NSString).substring(with: range)
            var styles: Set<Span.Style> = []
            if let font = attributes[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) { styles.insert(.bold) }
                if traits.contains(.traitItalic) { styles.insert(.italic) }
            }
            if attributes[.underlineStyle] != nil { styles.insert(.underline) }
            if attributes[.strikethroughStyle] != nil { styles.insert(.strikethrough) }
            if attributes[.backgroundColor] != nil { styles.insert(.highlight) }
            if let offset = attributes[.baselineOffset] as? NSNumber {
                if offset.doubleValue > 0 { styles.insert(.superscript) }
                if offset.doubleValue < 0 { styles.insert(.subscriptText) }
            }
            let link = (attributes[.link] as? URL)?.absoluteString
            let span = Span(text, styles: styles, link: link)
            if let last = output.last, last.hasSameFormatting(as: span) {
                output[output.count - 1].text += text
            } else { output.append(span) }
        }
        return output
    }

    private static func color(_ value: Span.TextColor?) -> UIColor {
        switch value {
        case .red: .systemRed; case .orange: .systemOrange; case .yellow: .systemYellow
        case .green: .systemGreen; case .mint: .systemMint; case .teal: .systemTeal
        case .cyan: .systemCyan; case .blue: .systemBlue; case .indigo: .systemIndigo
        case .purple: .systemPurple; case .pink: .systemPink; case .brown: .systemBrown
        case .gray: .systemGray; case nil: .label
        }
    }
}
#endif
