import AppKit
import NeoAnkiCore
import SwiftUI

private final class TextViewHolder {
    weak var textView: NSTextView?
    var lastSelectedRange = NSRange(location: NSNotFound, length: 0)
}

private final class UndoAttributedString: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = NSAttributedString(attributedString: value)
    }
}

struct RichTextFieldEditor: View {
    let label: String
    @Binding var spans: [Span]
    var accessibilityIdentifier: String?
    var isFocused: Binding<Bool>?

    @State private var textViewHolder = TextViewHolder()
    @State private var selectionFormatting = RichTextEditing.SelectionState.empty
    @State private var linkDraft = "https://"
    @State private var isLinkEditorPresented = false
    @FocusState private var isLinkFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
            Text(label)
                .font(DesignSystem.Typography.uiHint)
                .foregroundStyle(.secondary)

            formattingToolbar

            RichTextEditorRepresentable(
                label: label,
                spans: $spans,
                accessibilityIdentifier: accessibilityIdentifier,
                textViewHolder: textViewHolder,
                isFocused: isFocused,
                selectionFormatting: $selectionFormatting
            )
            .frame(minHeight: 88)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            if ProcessInfo.processInfo.environment["NEOANKI_TESTING"] == "1",
               let accessibilityIdentifier {
                Text(SpanFormatting.testingDescription(from: spans))
                    .accessibilityIdentifier("\(accessibilityIdentifier)-spans")
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
        }
        .alert("Add Link", isPresented: $isLinkEditorPresented) {
            TextField("https://example.com", text: $linkDraft)
                .focused($isLinkFieldFocused)
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                guard let link = normalizedLinkDraft else { return }
                RichTextEditing.setLink(
                    link,
                    in: textViewHolder.textView,
                    preferredRange: textViewHolder.lastSelectedRange
                )
                refreshSelectionFormatting()
            }
            .disabled(normalizedLinkDraft == nil)
        } message: {
            Text("Use an HTTP, HTTPS, or mailto link.")
        }
        .onChange(of: isLinkEditorPresented) { _, isPresented in
            if isPresented {
                isLinkFieldFocused = true
            } else {
                textViewHolder.textView?.window?.makeFirstResponder(textViewHolder.textView)
            }
        }
    }

    private var formattingToolbar: some View {
        HStack(spacing: 2) {
            FormatButton(title: "Bold", systemImage: "bold", state: controlState(for: .bold), accessibilityIdentifier: formatButtonID("formatBold")) {
                RichTextEditing.toggleStyle(.bold, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                refreshSelectionFormatting()
            }
            FormatButton(title: "Italic", systemImage: "italic", state: controlState(for: .italic), accessibilityIdentifier: formatButtonID("formatItalic")) {
                RichTextEditing.toggleStyle(.italic, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                refreshSelectionFormatting()
            }
            FormatButton(title: "Underline", systemImage: "underline", state: controlState(for: .underline), accessibilityIdentifier: formatButtonID("formatUnderline")) {
                RichTextEditing.toggleStyle(.underline, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                refreshSelectionFormatting()
            }
            FormatButton(title: "Strikethrough", systemImage: "strikethrough", state: controlState(for: .strikethrough), accessibilityIdentifier: formatButtonID("formatStrikethrough")) {
                RichTextEditing.toggleStyle(.strikethrough, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                refreshSelectionFormatting()
            }
            FormatButton(title: "Highlight", systemImage: "highlighter", state: controlState(for: .highlight), accessibilityIdentifier: formatButtonID("formatHighlight")) {
                RichTextEditing.toggleStyle(.highlight, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                refreshSelectionFormatting()
            }
            FormatButton(title: "Code", systemImage: "chevron.left.forwardslash.chevron.right", state: controlState(for: .code), accessibilityIdentifier: formatButtonID("formatCode")) {
                RichTextEditing.toggleStyle(.code, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                refreshSelectionFormatting()
            }

            Menu {
                Button("Superscript", systemImage: menuImage(for: .superscript, fallback: "textformat.superscript")) {
                    RichTextEditing.toggleStyle(.superscript, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                    refreshSelectionFormatting()
                }
                Button("Subscript", systemImage: menuImage(for: .subscriptText, fallback: "textformat.subscript")) {
                    RichTextEditing.toggleStyle(.subscriptText, in: textViewHolder.textView, preferredRange: textViewHolder.lastSelectedRange)
                    refreshSelectionFormatting()
                }

                Menu("Text Size", systemImage: "textformat.size") {
                    Button("Small", systemImage: sizeMenuImage(for: .small)) {
                        setTextSize(.small)
                    }
                    Button("Default", systemImage: sizeMenuImage(for: nil)) {
                        setTextSize(nil)
                    }
                    Button("Large", systemImage: sizeMenuImage(for: .large)) {
                        setTextSize(.large)
                    }
                }

                Menu("Text Color", systemImage: "paintpalette") {
                    Button("Default", systemImage: colorMenuImage(for: nil)) {
                        setTextColor(nil)
                    }
                    ForEach(Span.TextColor.allCases, id: \.self) { color in
                        Button {
                            setTextColor(color)
                        } label: {
                            Label {
                                Text(color.displayName)
                            } icon: {
                                Image(systemName: colorMenuImage(for: color))
                                    .foregroundStyle(Color(nsColor: SpanFormatting.nsColor(for: color)))
                            }
                        }
                    }
                }

                Divider()

                Button(selectionFormatting.link == nil ? "Add Link…" : "Edit Link…", systemImage: "link") {
                    linkDraft = selectionFormatting.link ?? "https://"
                    isLinkEditorPresented = true
                }
                Button("Remove Link", systemImage: "link.badge.minus") {
                    RichTextEditing.setLink(
                        nil,
                        in: textViewHolder.textView,
                        preferredRange: textViewHolder.lastSelectedRange
                    )
                    refreshSelectionFormatting()
                }

                Divider()

                Button("Clear Formatting", systemImage: "eraser") {
                    RichTextEditing.clearFormatting(
                        in: textViewHolder.textView,
                        preferredRange: textViewHolder.lastSelectedRange
                    )
                    refreshSelectionFormatting()
                }
            } label: {
                Label("More Formatting", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .help("More Formatting")
            .accessibilityValue(selectionFormatting.accessibilitySummary)
            .accessibilityIdentifier(formatButtonID("formatMore") ?? "More Formatting")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private func formatButtonID(_ suffix: String) -> String? {
        guard let accessibilityIdentifier else { return nil }
        return "\(accessibilityIdentifier)-\(suffix)"
    }

    private var normalizedLinkDraft: String? {
        let trimmed = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") || trimmed.lowercased().hasPrefix("mailto:")
            ? trimmed
            : "https://\(trimmed)"
        return RichTextValidation.isValidLink(candidate) ? candidate : nil
    }

    private func setTextColor(_ color: Span.TextColor?) {
        RichTextEditing.setTextColor(
            color,
            in: textViewHolder.textView,
            preferredRange: textViewHolder.lastSelectedRange
        )
        refreshSelectionFormatting()
    }

    private func setTextSize(_ size: Span.TextSize?) {
        RichTextEditing.setTextSize(
            size,
            in: textViewHolder.textView,
            preferredRange: textViewHolder.lastSelectedRange
        )
        refreshSelectionFormatting()
    }

    private func controlState(for style: Span.Style) -> FormatControlState {
        if selectionFormatting.mixedStyles.contains(style) {
            return .mixed
        }
        return selectionFormatting.activeStyles.contains(style) ? .active : .inactive
    }

    private func menuImage(for style: Span.Style, fallback: String) -> String {
        switch controlState(for: style) {
        case .active: "checkmark"
        case .mixed: "minus"
        case .inactive: fallback
        }
    }

    private func sizeMenuImage(for size: Span.TextSize?) -> String {
        if selectionFormatting.textSizeIsMixed {
            return "minus"
        }
        if selectionFormatting.textSize == size {
            return "checkmark"
        }
        return switch size {
        case .small: "textformat.size.smaller"
        case .large: "textformat.size.larger"
        case nil: "textformat"
        }
    }

    private func colorMenuImage(for color: Span.TextColor?) -> String {
        if selectionFormatting.textColorIsMixed {
            return "minus.circle"
        }
        return selectionFormatting.textColor == color ? "checkmark.circle.fill" : "circle.fill"
    }

    private func refreshSelectionFormatting() {
        guard let textView = textViewHolder.textView else {
            selectionFormatting = .empty
            return
        }

        // Toolbar actions mutate NSTextStorage before the delegate publishes the
        // corresponding binding update. Keep the model in sync immediately so
        // this state change cannot make SwiftUI restore the pre-formatting value.
        let updatedSpans = SpanFormatting.spans(from: textView.attributedString())
        if updatedSpans != spans {
            spans = updatedSpans
        }
        selectionFormatting = RichTextEditing.selectionState(in: textView)
    }
}

private enum FormatControlState: String {
    case inactive = "Off"
    case active = "On"
    case mixed = "Mixed"
}

private struct FormatButton: View {
    let title: String
    let systemImage: String
    let state: FormatControlState
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .padding(5)
            .background(
                state == .active ? Color.accentColor.opacity(0.18) :
                    state == .mixed ? Color.secondary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .help(title)
            .accessibilityValue(state.rawValue)
            .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }
}

private struct RichTextEditorRepresentable: NSViewRepresentable {
    let label: String
    @Binding var spans: [Span]
    var accessibilityIdentifier: String?
    var textViewHolder: TextViewHolder
    var isFocused: Binding<Bool>?
    @Binding var selectionFormatting: RichTextEditing.SelectionState

    func makeCoordinator() -> Coordinator {
        Coordinator(
            spans: $spans,
            textViewHolder: textViewHolder,
            isFocused: isFocused,
            selectionFormatting: $selectionFormatting
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(label)
        context.coordinator.textView = textView
        textViewHolder.textView = textView

        context.coordinator.setAttributedString(
            SpanFormatting.attributedString(from: spans),
            preservingSelection: false
        )
        if isFocused?.wrappedValue == true {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    @MainActor
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        context.coordinator.isFocused = isFocused
        textViewHolder.textView = textView
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(label)

        if isFocused?.wrappedValue == true, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        guard !context.coordinator.isUpdatingFromView else { return }

        let currentSpans = SpanFormatting.spans(from: textView.attributedString())
        if currentSpans != spans {
            context.coordinator.setAttributedString(
                SpanFormatting.attributedString(from: spans),
                preservingSelection: true
            )
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var spans: [Span]
        weak var textView: NSTextView?
        var isUpdatingFromView = false
        var isProgrammaticUpdate = false
        let textViewHolder: TextViewHolder
        var isFocused: Binding<Bool>?
        @Binding var selectionFormatting: RichTextEditing.SelectionState

        init(
            spans: Binding<[Span]>,
            textViewHolder: TextViewHolder,
            isFocused: Binding<Bool>?,
            selectionFormatting: Binding<RichTextEditing.SelectionState>
        ) {
            _spans = spans
            self.textViewHolder = textViewHolder
            self.isFocused = isFocused
            _selectionFormatting = selectionFormatting
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isProgrammaticUpdate else { return }
            Task { @MainActor in
                sanitizeContentsIfNeeded(in: textView)
                publishSpans(from: textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textViewHolder.lastSelectedRange = textView.selectedRange()
            Task { @MainActor in
                selectionFormatting = RichTextEditing.selectionState(in: textView)
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused?.wrappedValue = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               textView.string.isEmpty {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.string.isEmpty else { return }
                    RichTextEditing.resetTypingAttributes(in: textView)
                }
            }

            switch RichTextFocusNavigation.direction(for: commandSelector) {
            case .forward:
                isFocused?.wrappedValue = false
                textView.window?.selectNextKeyView(textView)
                return true
            case .backward:
                isFocused?.wrappedValue = false
                textView.window?.selectPreviousKeyView(textView)
                return true
            case nil:
                return false
            }
        }

        @MainActor
        func setAttributedString(_ attributedString: NSAttributedString, preservingSelection: Bool) {
            guard let textView else { return }
            isProgrammaticUpdate = true
            defer { isProgrammaticUpdate = false }

            let selectedRange = preservingSelection ? textView.selectedRange() : NSRange(location: 0, length: 0)
            textView.textStorage?.setAttributedString(attributedString)
            let length = textView.textStorage?.length ?? 0
            let clampedLocation = min(selectedRange.location, length)
            let clampedLength = min(selectedRange.length, length - clampedLocation)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
            if length == 0 {
                RichTextEditing.resetTypingAttributes(in: textView)
            }
            selectionFormatting = RichTextEditing.selectionState(in: textView)
        }

        @MainActor
        private func publishSpans(from textView: NSTextView) {
            let newSpans = SpanFormatting.spans(from: textView.attributedString())
            if textView.string.isEmpty {
                RichTextEditing.resetTypingAttributes(in: textView)
            }
            selectionFormatting = RichTextEditing.selectionState(in: textView)
            guard newSpans != spans else { return }

            isUpdatingFromView = true
            defer { isUpdatingFromView = false }
            spans = newSpans
        }

        @MainActor
        private func sanitizeContentsIfNeeded(in textView: NSTextView) {
            // Rewriting marked text breaks input methods while they are composing.
            guard !textView.hasMarkedText() else { return }

            let current = textView.attributedString()
            let sanitized = RichTextEditing.sanitizedAttributedString(current)
            guard !current.isEqual(to: sanitized) else { return }

            isProgrammaticUpdate = true
            defer { isProgrammaticUpdate = false }

            let selectedRange = RichTextEditing.sanitizedSelection(
                textView.selectedRange(),
                from: current
            )
            textView.textStorage?.setAttributedString(sanitized)
            let length = sanitized.length
            let location = min(selectedRange.location, length)
            let selectionLength = min(selectedRange.length, length - location)
            textView.setSelectedRange(NSRange(location: location, length: selectionLength))
            RichTextEditing.synchronizeTypingAttributes(in: textView)
            selectionFormatting = RichTextEditing.selectionState(in: textView)
        }
    }
}

enum RichTextFocusNavigation {
    enum Direction: Equatable {
        case forward
        case backward
    }

    static func direction(for selector: Selector) -> Direction? {
        if selector == #selector(NSResponder.insertTab(_:)) {
            return .forward
        }
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            return .backward
        }
        return nil
    }
}

enum RichTextEditing {
    struct SelectionState: Equatable {
        var activeStyles: Set<Span.Style>
        var mixedStyles: Set<Span.Style>
        var textColor: Span.TextColor?
        var textColorIsMixed: Bool
        var textSize: Span.TextSize?
        var textSizeIsMixed: Bool
        var link: String?
        var linkIsMixed: Bool

        static let empty = SelectionState(
            activeStyles: [],
            mixedStyles: [],
            textColor: nil,
            textColorIsMixed: false,
            textSize: nil,
            textSizeIsMixed: false,
            link: nil,
            linkIsMixed: false
        )

        var accessibilitySummary: String {
            if !mixedStyles.isEmpty || textColorIsMixed || textSizeIsMixed || linkIsMixed {
                return "Selection contains mixed formatting"
            }
            var values = activeStyles.map(\.rawValue).sorted()
            if let textColor {
                values.append("\(textColor.rawValue) text")
            }
            if let textSize {
                values.append("\(textSize.rawValue) text")
            }
            if link != nil {
                values.append("link")
            }
            return values.isEmpty ? "No active formatting" : values.joined(separator: ", ")
        }
    }

    @MainActor
    static func selectionState(in textView: NSTextView?) -> SelectionState {
        guard let textView, let textStorage = textView.textStorage else { return .empty }
        let selection = textView.selectedRange()
        if selection.length == 0 || !rangeIsValid(selection, for: textStorage.length) {
            return selectionState(from: [span(from: textView.typingAttributes)])
        }

        var spans: [Span] = []
        textStorage.enumerateAttributes(in: selection) { attributes, _, _ in
            spans.append(span(from: attributes))
        }
        return selectionState(from: spans)
    }

    @MainActor
    static func synchronizeTypingAttributes(in textView: NSTextView) {
        guard let textStorage = textView.textStorage, textStorage.length > 0 else {
            resetTypingAttributes(in: textView)
            return
        }
        let selection = textView.selectedRange()
        let location = selection.location == NSNotFound
            ? textStorage.length
            : min(max(0, selection.location), textStorage.length)
        let attributeIndex = location > 0 ? location - 1 : 0
        textView.typingAttributes = attributes(
            for: span(from: textStorage.attributes(at: attributeIndex, effectiveRange: nil))
        )
    }

    @MainActor
    static func resetTypingAttributes(in textView: NSTextView) {
        textView.typingAttributes = SpanFormatting.defaultTypingAttributes
    }

    @MainActor
    static func toggleStyle(
        _ style: Span.Style,
        in textView: NSTextView?,
        preferredRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let range = resolvedRange(
            in: textView,
            textLength: textStorage.length,
            preferredRange: preferredRange
        )
        if range != textView.selectedRange() {
            textView.setSelectedRange(range)
        }
        let targetRange = range.length > 0 ? range : NSRange(location: range.location, length: 0)
        let isActive = styleIsActive(style, in: textStorage, range: targetRange, typingAttributes: textView.typingAttributes)
        let applying = !isActive

        if range.length == 0 {
            var span = span(from: textView.typingAttributes)
            applyStyle(style, active: applying, to: &span)
            textView.typingAttributes = attributes(for: span)
            return
        }

        applyFormatting(in: range, textView: textView) { span in
            applyStyle(style, active: applying, to: &span)
        }
    }

    @MainActor
    static func setTextColor(
        _ color: Span.TextColor?,
        in textView: NSTextView?,
        preferredRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        applyFormatting(in: textView, preferredRange: preferredRange) {
            $0.textColor = color
        }
    }

    @MainActor
    static func setTextSize(
        _ size: Span.TextSize?,
        in textView: NSTextView?,
        preferredRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        applyFormatting(in: textView, preferredRange: preferredRange) {
            $0.textSize = size
        }
    }

    @MainActor
    static func setLink(
        _ link: String?,
        in textView: NSTextView?,
        preferredRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        if let link, !RichTextValidation.isValidLink(link) {
            return
        }
        applyFormatting(in: textView, preferredRange: preferredRange) {
            $0.link = link
        }
    }

    @MainActor
    static func clearFormatting(
        in textView: NSTextView?,
        preferredRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        applyFormatting(in: textView, preferredRange: preferredRange) { span in
            span.styles = []
            span.textColor = nil
            span.textSize = nil
            span.link = nil
        }
    }

    static func sanitizedAttributedString(
        _ attributedString: NSAttributedString
    ) -> NSAttributedString {
        SpanFormatting.attributedString(
            from: SpanFormatting.spans(from: attributedString)
        )
    }

    static func sanitizedSelection(
        _ selection: NSRange,
        from attributedString: NSAttributedString
    ) -> NSRange {
        let length = attributedString.length
        let start = selection.location == NSNotFound || selection.location < 0
            ? length
            : min(selection.location, length)
        let selectedLength = min(max(0, selection.length), length - start)
        let end = start + selectedLength

        func attachmentLength(before boundary: Int) -> Int {
            guard boundary > 0 else { return 0 }
            var removedLength = 0
            attributedString.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: boundary)
            ) { value, range, _ in
                if value != nil {
                    removedLength += range.length
                }
            }
            return removedLength
        }

        let sanitizedStart = start - attachmentLength(before: start)
        let sanitizedEnd = end - attachmentLength(before: end)
        return NSRange(
            location: sanitizedStart,
            length: max(0, sanitizedEnd - sanitizedStart)
        )
    }

    private static func selectionState(from spans: [Span]) -> SelectionState {
        guard let first = spans.first else { return .empty }
        var commonStyles = first.styles
        var allStyles = first.styles
        var textColorIsMixed = false
        var textSizeIsMixed = false
        var linkIsMixed = false

        for span in spans.dropFirst() {
            commonStyles.formIntersection(span.styles)
            allStyles.formUnion(span.styles)
            textColorIsMixed = textColorIsMixed || span.textColor != first.textColor
            textSizeIsMixed = textSizeIsMixed || span.textSize != first.textSize
            linkIsMixed = linkIsMixed || span.link != first.link
        }

        return SelectionState(
            activeStyles: commonStyles,
            mixedStyles: allStyles.subtracting(commonStyles),
            textColor: textColorIsMixed ? nil : first.textColor,
            textColorIsMixed: textColorIsMixed,
            textSize: textSizeIsMixed ? nil : first.textSize,
            textSizeIsMixed: textSizeIsMixed,
            link: linkIsMixed ? nil : first.link,
            linkIsMixed: linkIsMixed
        )
    }

    private static func rangeIsValid(_ range: NSRange, for textLength: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= textLength
            && range.length <= textLength - range.location
    }

    private static func styleIsActive(
        _ style: Span.Style,
        in textStorage: NSTextStorage,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> Bool {
        if range.length == 0 {
            return SpanFormatting.spans(from: NSAttributedString(string: "x", attributes: typingAttributes))
                .first?.styles.contains(style) == true
        }

        var found = false
        var allActive = true
        textStorage.enumerateAttributes(in: range) { attributes, _, stop in
            found = true
            let styles = SpanFormatting.spans(from: NSAttributedString(string: "x", attributes: attributes))
                .first?.styles ?? []
            if !styles.contains(style) {
                allActive = false
                stop.pointee = true
            }
        }
        return found && allActive
    }

    private static func applyStyle(
        _ style: Span.Style,
        active: Bool,
        to span: inout Span
    ) {
        if active {
            if style == .code {
                span.styles.remove(.highlight)
            } else if style == .highlight {
                span.styles.remove(.code)
            } else if style == .superscript {
                span.styles.remove(.subscriptText)
            } else if style == .subscriptText {
                span.styles.remove(.superscript)
            }
            span.styles.insert(style)
        } else {
            span.styles.remove(style)
        }
    }

    @MainActor
    private static func applyFormatting(
        in textView: NSTextView?,
        preferredRange: NSRange,
        update: (inout Span) -> Void
    ) {
        guard let textView, let textStorage = textView.textStorage else { return }
        let range = resolvedRange(
            in: textView,
            textLength: textStorage.length,
            preferredRange: preferredRange
        )
        if range != textView.selectedRange() {
            textView.setSelectedRange(range)
        }

        if range.length == 0 {
            var span = span(from: textView.typingAttributes)
            update(&span)
            textView.typingAttributes = attributes(for: span)
            return
        }

        applyFormatting(in: range, textView: textView, update: update)
    }

    @MainActor
    private static func applyFormatting(
        in range: NSRange,
        textView: NSTextView,
        update: (inout Span) -> Void
    ) {
        guard let textStorage = textView.textStorage else { return }
        guard rangeIsValid(range, for: textStorage.length) else {
            return
        }

        let previousValue = textStorage.attributedSubstring(from: range)
        var updates: [(NSRange, [NSAttributedString.Key: Any])] = []
        textStorage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var span = span(from: attributes)
            update(&span)
            updates.append((subrange, self.attributes(for: span)))
        }

        textStorage.beginEditing()
        for (subrange, attributes) in updates {
            textStorage.setAttributes(attributes, range: subrange)
        }
        textStorage.endEditing()

        let updatedValue = textStorage.attributedSubstring(from: range)
        guard !previousValue.isEqual(to: updatedValue) else { return }

        registerUndo(
            previousValue,
            in: range,
            selectedRange: textView.selectedRange(),
            textView: textView
        )
        textView.didChangeText()
    }

    @MainActor
    private static func registerUndo(
        _ attributedString: NSAttributedString,
        in range: NSRange,
        selectedRange: NSRange,
        textView: NSTextView
    ) {
        let undoValue = UndoAttributedString(attributedString)
        textView.undoManager?.registerUndo(withTarget: textView) { target in
            MainActor.assumeIsolated {
                guard let textStorage = target.textStorage,
                      rangeIsValid(range, for: textStorage.length)
                else {
                    return
                }

                let inverseValue = textStorage.attributedSubstring(from: range)
                textStorage.replaceCharacters(in: range, with: undoValue.value)
                target.setSelectedRange(selectedRange)
                registerUndo(
                    inverseValue,
                    in: range,
                    selectedRange: selectedRange,
                    textView: target
                )
                target.didChangeText()
            }
        }
        textView.undoManager?.setActionName("Change Formatting")
    }

    @MainActor
    private static func resolvedRange(
        in textView: NSTextView,
        textLength: Int,
        preferredRange: NSRange
    ) -> NSRange {
        let selection = textView.selectedRange()
        if selection.length > 0,
           rangeIsValid(selection, for: textLength) {
            return selection
        }
        if preferredRange.length > 0,
           rangeIsValid(preferredRange, for: textLength) {
            return preferredRange
        }
        let location = selection.location == NSNotFound
            ? textLength
            : min(selection.location, textLength)
        return NSRange(location: location, length: 0)
    }

    private static func span(
        from attributes: [NSAttributedString.Key: Any]
    ) -> Span {
        SpanFormatting.spans(
            from: NSAttributedString(string: "x", attributes: attributes)
        ).first ?? Span("x")
    }

    private static func attributes(
        for span: Span
    ) -> [NSAttributedString.Key: Any] {
        SpanFormatting.attributedString(from: [span])
            .attributes(at: 0, effectiveRange: nil)
    }
}

private extension Span.TextColor {
    var displayName: String {
        rawValue.capitalized
    }
}
