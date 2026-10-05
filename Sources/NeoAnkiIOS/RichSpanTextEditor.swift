#if os(iOS)
import NeoAnkiCore
import SwiftUI
import UIKit

struct MobileTextEditorHeight: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 96

    func body(content: Content) -> some View { content.frame(minHeight: height) }
}

struct RichSpanTextEditor: UIViewRepresentable {
    @Binding var spans: [Span]
    private static let spanColorKey = NSAttributedString.Key("NeoAnki.span.textColor")
    private static let spanSizeKey = NSAttributedString.Key("NeoAnki.span.textSize")
    private static let codeKey = NSAttributedString.Key("NeoAnki.span.code")

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
        context.coordinator.updateBinding($spans)
        guard !context.coordinator.isPublishing else { return }
        if Self.spans(from: view.attributedText) != spans {
            context.coordinator.isPublishing = true
            defer { context.coordinator.isPublishing = false }
            view.attributedText = Self.attributed(spans)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var spans: [Span]
        var isPublishing = false
        init(spans: Binding<[Span]>) { _spans = spans }
        func updateBinding(_ value: Binding<[Span]>) { _spans = value }
        func textViewDidChange(_ textView: UITextView) {
            guard !isPublishing else { return }
            isPublishing = true
            spans = RichSpanTextEditor.spans(from: textView.attributedText)
            isPublishing = false
        }
    }

    static func attributed(_ spans: [Span]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in spans {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if span.styles.contains(.bold) { traits.insert(.traitBold) }
            if span.styles.contains(.italic) { traits.insert(.traitItalic) }
            let base = UIFont.preferredFont(forTextStyle: span.textSize == .large ? .title3 : span.textSize == .small ? .footnote : .body)
            let descriptor = span.styles.contains(.code)
                ? base.fontDescriptor.withDesign(.monospaced) ?? base.fontDescriptor
                : base.fontDescriptor
            let font = descriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: 0) } ?? base
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(span.textColor)]
            // UIKit preserves custom run attributes while editing. Keep the
            // portable semantics instead of trying to infer them from RGB or
            // scaled point sizes when rebuilding persisted spans.
            if let value = span.textColor { attributes[spanColorKey] = value.rawValue }
            if let value = span.textSize { attributes[spanSizeKey] = value.rawValue }
            if span.styles.contains(.code) {
                attributes[codeKey] = true
                attributes[.backgroundColor] = UIColor.tertiarySystemFill
            }
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

    static func spans(from value: NSAttributedString) -> [Span] {
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
            if let value = attributes[.underlineStyle] as? NSNumber, value.intValue != 0 { styles.insert(.underline) }
            if let value = attributes[.strikethroughStyle] as? NSNumber, value.intValue != 0 { styles.insert(.strikethrough) }
            let isCode = (attributes[codeKey] as? NSNumber)?.boolValue == true
            if isCode { styles.insert(.code) }
            else if attributes[.backgroundColor] != nil { styles.insert(.highlight) }
            if let offset = attributes[.baselineOffset] as? NSNumber {
                if offset.doubleValue > 0 { styles.insert(.superscript) }
                if offset.doubleValue < 0 { styles.insert(.subscriptText) }
            }
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            let textColor = (attributes[spanColorKey] as? String).flatMap(Span.TextColor.init(rawValue:))
            let textSize = (attributes[spanSizeKey] as? String).flatMap(Span.TextSize.init(rawValue:))
            let span = Span(text, styles: styles, textColor: textColor, textSize: textSize, link: link)
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
