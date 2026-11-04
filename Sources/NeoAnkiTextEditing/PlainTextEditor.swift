import SwiftUI

/// Owned by the draft, so preview navigation does not destroy native editing history.
@MainActor @Observable
public final class PlainTextEditorSession {
    public init() {}
    public var isFocused = false
    public func focus() {
        #if os(macOS)
        guard let view = scrollView?.documentView else { return }
        view.window?.makeFirstResponder(view)
        #endif
    }
    #if os(macOS)
    @ObservationIgnored var scrollView: NSScrollView?
    #endif
}

/// Stable sessions for dynamically generated fields; creating a session does
/// not publish view state while SwiftUI is evaluating the form.
@MainActor
public final class PlainTextEditorSessions {
    private var sessions: [AnyHashable: PlainTextEditorSession] = [:]
    public init() {}
    public func session(for id: AnyHashable) -> PlainTextEditorSession {
        if let session = sessions[id] { return session }
        let session = PlainTextEditorSession()
        sessions[id] = session
        return session
    }
    public func retain(identifiers: Set<AnyHashable>) {
        sessions = sessions.filter { identifiers.contains($0.key) }
    }
}

public struct PlainTextEditor: View {
    @Binding private var text: String
    private let session: PlainTextEditorSession
    private let label: String
    private let identifier: String

    public init(text: Binding<String>, session: PlainTextEditorSession, label: String, identifier: String) {
        _text = text
        self.session = session
        self.label = label
        self.identifier = identifier
    }

    public var body: some View {
        #if os(macOS)
        NativePlainTextEditor(text: $text, session: session, label: label, identifier: identifier)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(session.isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: session.isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
        #else
        TextEditor(text: $text)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        #endif
    }
}

#if os(macOS)
import AppKit

private final class NotificationObservations {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

final class PlainTextView: NSTextView {
    private let history = UndoManager()
    private let historyObservers = NotificationObservations()
    private var ownedStorage: NSTextStorage?
    override var undoManager: UndoManager? { history }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        let container: NSTextContainer
        if let textContainer { container = textContainer }
        else {
            let storage = NSTextStorage()
            ownedStorage = storage
            let layout = NSLayoutManager()
            container = NSTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
        }
        super.init(frame: frame, textContainer: container)
        observeHistory()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeHistory()
    }
    private func observeHistory() {
        // UndoManager can restore NSTextStorage without the normal typing
        // delegate callback, including after an editor remounts from preview.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            historyObservers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: history, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.didChangeText()
                }
            })
        }
    }
}

struct NativePlainTextEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let session: PlainTextEditorSession
    let label: String
    let identifier: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = makeNativeScrollView()
        updateNSView(scroll, context: context)
        return scroll
    }

    func makeNativeScrollView() -> NSScrollView {
        let scroll: NSScrollView
        if let retained = session.scrollView {
            scroll = retained
        } else {
            let view = PlainTextView(frame: .zero, textContainer: nil)
            view.isRichText = false
            view.isSelectable = true
            view.importsGraphics = false
            view.allowsUndo = true
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.minSize = .zero
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.textContainerInset = NSSize(width: 12, height: 12)
            view.font = .preferredFont(forTextStyle: .body)
            view.textColor = .textColor
            view.backgroundColor = .textBackgroundColor
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            view.string = text
            scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = true
            scroll.backgroundColor = .textBackgroundColor
            scroll.documentView = view
            session.scrollView = scroll
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        updateNativeView(scroll, coordinator: context.coordinator)
    }

    func updateNativeView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.delegate = coordinator
        view.isEditable = isEnabled
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(identifier)
        // Replacing text during composition breaks input methods. The delegate
        // publishes the committed native text before the next binding update.
        guard view.string != text, !view.hasMarkedText() else { return }
        let selected = view.selectedRange()
        let origin = scroll.contentView.bounds.origin
        coordinator.isSynchronizing = true
        view.breakUndoCoalescing()
        view.insertText(text, replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        view.breakUndoCoalescing()
        view.undoManager?.setActionName("Replace Text")
        view.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count),
                                     length: min(selected.length, max(0, text.utf16.count - selected.location))))
        scroll.contentView.scroll(to: origin)
        coordinator.isSynchronizing = false
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? NSTextView, view.delegate === coordinator else { return }
        view.delegate = nil
        coordinator.parent.session.isFocused = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePlainTextEditor
        var isSynchronizing = false
        init(parent: NativePlainTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing, let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }
        func textDidBeginEditing(_ notification: Notification) { parent.session.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.session.isFocused = false }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(textView)
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(textView)
                return true
            }
            return false
        }
    }
}
#endif
