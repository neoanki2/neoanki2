import SwiftUI

public struct EditingUndoContext {
    public var canUndo: Bool
    public var canRedo: Bool
    public var undo: () -> Void
    public var redo: () -> Void
    public init(canUndo: Bool, canRedo: Bool = false, undo: @escaping () -> Void, redo: @escaping () -> Void = {}) {
        self.canUndo = canUndo; self.canRedo = canRedo
        self.undo = undo; self.redo = redo
    }
}

extension View {
    /// App-local shortcuts never take input from a text responder or a child sheet.
    public func editingShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command,
                                isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        background(EditingAnchor(shortcut: .init(key: key, modifiers: modifiers, enabled: isEnabled, action: action)))
        #else
        self
        #endif
    }

    public func editingUndoContext(_ context: EditingUndoContext) -> some View {
        #if os(macOS)
        background(EditingAnchor(undoContext: context))
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

/// Pure routing decisions are exercised without creating application windows.
enum EditingCommandPolicy {
    enum UndoOwner: Equatable { case text, context, none }
    static func undoOwner(textOwnsFocus: Bool, hasContext: Bool) -> UndoOwner {
        textOwnsFocus ? .text : hasContext ? .context : .none
    }
    static func permitsShortcut(textOwnsFocus: Bool, sameWindow: Bool, hasSheet: Bool,
                                enabled: Bool, isRepeat: Bool) -> Bool {
        !textOwnsFocus && sameWindow && !hasSheet && enabled && !isRepeat
    }
    static func deliversReturnToEditor(keyCode: UInt16, isFieldEditor: Bool, hasModifiers: Bool) -> Bool {
        (keyCode == 36 || keyCode == 76) && !isFieldEditor && !hasModifiers
    }
}

struct EditingShortcut {
    var key: KeyEquivalent
    var modifiers: EventModifiers
    var enabled: Bool
    var action: () -> Void

    func matches(_ event: NSEvent) -> Bool {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return event.charactersIgnoringModifiers?.lowercased() == String(key.character).lowercased()
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == flags
    }
}

struct EditingAnchor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var shortcut: EditingShortcut?
    var undoContext: EditingUndoContext?
    func makeNSView(context: Context) -> EditingAnchorView { EditingAnchorView() }
    func updateNSView(_ view: EditingAnchorView, context: Context) {
        view.shortcut = shortcut
        if view.shortcut != nil { view.shortcut?.enabled = (shortcut?.enabled ?? false) && isEnabled }
        view.undoContext = undoContext
        EditingRouter.shared.register(view)
    }
    static func dismantleNSView(_ view: EditingAnchorView, coordinator: ()) {
        EditingRouter.shared.unregister(view)
    }
}

final class EditingAnchorView: NSView {
    var shortcut: EditingShortcut?
    var undoContext: EditingUndoContext?
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor @Observable
final class EditingRouter {
    static let shared = EditingRouter()
    private struct Entry { weak var view: EditingAnchorView? }
    private var entries: [Entry] = []
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    var canUndo = false
    var canRedo = false

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.route(event) ?? false }
            return handled ? nil : event
        }
        for name in [NSWindow.didUpdateNotification, NSText.didBeginEditingNotification,
                     NSText.didEndEditingNotification, NSText.didChangeNotification,
                     Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func register(_ view: EditingAnchorView) {
        entries.removeAll { $0.view == nil }
        if !entries.contains(where: { $0.view === view }) { entries.append(Entry(view: view)) }
        // Representable updates may run during a SwiftUI render.
        Task { @MainActor in refresh() }
    }
    func unregister(_ view: EditingAnchorView) {
        entries.removeAll { $0.view == nil || $0.view === view }
        Task { @MainActor in refresh() }
    }

    static func textOwnsFocus(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField || responder is NSTextInputClient
    }

    private func context(in window: NSWindow?) -> EditingUndoContext? {
        guard let window, window.attachedSheet == nil else { return nil }
        return entries.reversed().compactMap(\.view).first {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.undoContext != nil
        }?.undoContext
    }

    func refresh() {
        let window = NSApp?.keyWindow
        let responder = window?.firstResponder
        let nextUndo: Bool
        let nextRedo: Bool
        if Self.textOwnsFocus(responder) {
            nextUndo = responder?.undoManager?.canUndo ?? false
            nextRedo = responder?.undoManager?.canRedo ?? false
        } else {
            let active = context(in: window)
            nextUndo = active?.canUndo ?? false
            nextRedo = active?.canRedo ?? false
        }
        // Window updates must not themselves cause another menu/window update.
        if canUndo != nextUndo { canUndo = nextUndo }
        if canRedo != nextRedo { canRedo = nextRedo }
    }

    func performUndo(redo: Bool = false) {
        let window = NSApp?.keyWindow
        Self.performUndo(responder: window?.firstResponder, context: context(in: window), redo: redo)
        refresh()
    }

    static func performUndo(responder: NSResponder?, context active: EditingUndoContext?, redo: Bool = false) {
        switch EditingCommandPolicy.undoOwner(textOwnsFocus: Self.textOwnsFocus(responder), hasContext: active != nil) {
        case .text:
            let history = responder?.undoManager
            if redo { if history?.canRedo == true { history?.redo() } }
            else { if history?.canUndo == true { history?.undo() } }
        case .context:
            guard let active else { return }
            if redo { if active.canRedo { active.redo() } }
            else { if active.canUndo { active.undo() } }
        case .none:
            break
        }
    }

    private func route(_ event: NSEvent) -> Bool {
        let window = NSApp?.keyWindow
        if let text = window?.firstResponder as? NSTextView,
           event.window === window,
           EditingCommandPolicy.deliversReturnToEditor(keyCode: event.keyCode,
               isFieldEditor: text.isFieldEditor,
               hasModifiers: !event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty) {
            // A SwiftUI default-action button must not steal newline or an IME
            // commit from a multiline editor. Let NSTextView interpret it first.
            text.keyDown(with: event)
            return true
        }
        let ownsText = Self.textOwnsFocus(window?.firstResponder)
        for view in entries.reversed().compactMap(\.view) {
            guard let shortcut = view.shortcut, !view.isHiddenOrHasHiddenAncestor,
                  !(shortcut.modifiers.isEmpty && window?.firstResponder is NSControl),
                  EditingCommandPolicy.permitsShortcut(textOwnsFocus: ownsText,
                    sameWindow: window != nil && event.window === window && view.window === window,
                    hasSheet: window?.attachedSheet != nil, enabled: shortcut.enabled, isRepeat: event.isARepeat),
                  shortcut.matches(event) else { continue }
            shortcut.action()
            refresh()
            return true
        }
        return false
    }
}

public struct NativeEditingCommands: Commands {
    @State private var router = EditingRouter.shared
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { router.performUndo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!router.canUndo)
            Button("Redo") { router.performUndo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!router.canRedo)
        }
    }
}
#endif
