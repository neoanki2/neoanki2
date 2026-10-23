import SwiftUI
import Testing
@testable import NeoAnkiTextEditing

@Test @MainActor func dirtyDraftRequiresAnExplicitDecision() {
    let dismissal = DraftDismissal()
    var closed = 0
    dismissal.request(isDirty: true) { closed += 1 }
    #expect(dismissal.confirmsDiscard)
    #expect(closed == 0)
    dismissal.keepEditing()
    #expect(closed == 0)
    dismissal.request(isDirty: true) { closed += 1 }
    dismissal.discard()
    dismissal.discard()
    #expect(closed == 1)
}

@Test @MainActor func cleanDraftClosesAndBusyDraftDoesNot() {
    let dismissal = DraftDismissal()
    var closed = false
    dismissal.request(isDirty: false, isBusy: true) { closed = true }
    #expect(!closed)
    #expect(!dismissal.confirmsDiscard)
    dismissal.request(isDirty: false) { closed = true }
    #expect(closed)
}

#if os(macOS)
import AppKit

@Test func textAlwaysOwnsUndoEvenWhenItsHistoryIsEmpty() {
    #expect(EditingCommandPolicy.undoOwner(textOwnsFocus: true, hasContext: true) == .text)
    #expect(EditingCommandPolicy.undoOwner(textOwnsFocus: false, hasContext: true) == .context)
    #expect(EditingCommandPolicy.undoOwner(textOwnsFocus: false, hasContext: false) == .none)
}

@Test func returnBelongsToMultilineEditorsWhileFieldsKeepSubmit() {
    #expect(EditingCommandPolicy.deliversReturnToEditor(keyCode: 36, isFieldEditor: false, hasModifiers: false))
    #expect(EditingCommandPolicy.deliversReturnToEditor(keyCode: 76, isFieldEditor: false, hasModifiers: false))
    #expect(!EditingCommandPolicy.deliversReturnToEditor(keyCode: 36, isFieldEditor: true, hasModifiers: false))
    #expect(!EditingCommandPolicy.deliversReturnToEditor(keyCode: 36, isFieldEditor: false, hasModifiers: true))
    #expect(!EditingCommandPolicy.deliversReturnToEditor(keyCode: 49, isFieldEditor: false, hasModifiers: false))
}

@Test func shortcutsRequireAnUnobstructedNontextContext() {
    #expect(EditingCommandPolicy.permitsShortcut(textOwnsFocus: false, sameWindow: true, hasSheet: false, enabled: true, isRepeat: false))
    for (text, sameWindow, sheet, enabled, repeating) in [
        (true, true, false, true, false),
        (false, false, false, true, false),
        (false, true, true, true, false),
        (false, true, false, false, false),
        (false, true, false, true, true),
    ] {
        #expect(!EditingCommandPolicy.permitsShortcut(textOwnsFocus: text, sameWindow: sameWindow, hasSheet: sheet, enabled: enabled, isRepeat: repeating))
    }
}

@Test @MainActor func nativeTextAndFieldEditorsOwnTheirKeys() {
    #expect(EditingRouter.textOwnsFocus(NSTextView()))
    #expect(EditingRouter.textOwnsFocus(NSTextField()))
    #expect(!EditingRouter.textOwnsFocus(NSView()))
    #expect(!EditingRouter.textOwnsFocus(nil))
}

@Test @MainActor func independentNativeHistoriesPreserveUnicodeAndWhitespace() {
    let first = PlainTextView(frame: .zero, textContainer: nil)
    let second = PlainTextView(frame: .zero, textContainer: nil)
    first.allowsUndo = true
    second.allowsUndo = true
    let source = "  Весна 🌸\n\nSecond stanza\n"
    first.insertText(source, replacementRange: NSRange(location: 0, length: 0))
    first.breakUndoCoalescing()
    second.insertText("Another poem", replacementRange: NSRange(location: 0, length: 0))
    second.breakUndoCoalescing()
    #expect(first.string == source)
    first.undoManager?.undo()
    #expect(first.string.isEmpty)
    #expect(second.string == "Another poem")
    first.undoManager?.redo()
    #expect(first.string == source)
}

@Test @MainActor func previewRoundTripRetainsActualEditorSelectionAndUndo() throws {
    var draft = "First line\nSecond line"
    let session = PlainTextEditorSession()
    let editor = NativePlainTextEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                      session: session, label: "Poem", identifier: "poem")
    let coordinator = editor.makeCoordinator()
    let scroll = editor.makeNativeScrollView()
    editor.updateNativeView(scroll, coordinator: coordinator)
    let text = try #require(scroll.documentView as? NSTextView)
    #expect(text.allowsUndo)
    #expect(!text.isRichText)
    #expect(text.usesFindBar)
    #expect(!text.isAutomaticQuoteSubstitutionEnabled)
    text.setSelectedRange(NSRange(location: 5, length: 0))
    text.insertText(" new", replacementRange: text.selectedRange())
    text.breakUndoCoalescing()
    #expect(draft == "First new line\nSecond line")
    let selection = text.selectedRange()
    NativePlainTextEditor.dismantleNSView(scroll, coordinator: coordinator)
    let remounted = editor.makeNativeScrollView()
    editor.updateNativeView(remounted, coordinator: coordinator)
    #expect(remounted === scroll)
    #expect(text.selectedRange() == selection)
    text.undoManager?.undo()
    #expect(draft == "First line\nSecond line")
    text.undoManager?.redo()
    #expect(draft == "First new line\nSecond line")
}

@Test @MainActor func externalReplacementCanBeUndoneAndClampsSelection() throws {
    var draft = "Longer source"
    let editor = NativePlainTextEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                      session: PlainTextEditorSession(), label: "Source", identifier: "source")
    let coordinator = editor.makeCoordinator()
    let scroll = editor.makeNativeScrollView()
    editor.updateNativeView(scroll, coordinator: coordinator)
    let text = try #require(scroll.documentView as? NSTextView)
    text.setSelectedRange(NSRange(location: 10, length: 3))
    draft = "Short"
    editor.updateNativeView(scroll, coordinator: coordinator)
    #expect(text.string == "Short")
    #expect(text.selectedRange() == NSRange(location: 5, length: 0))
    text.undoManager?.undo()
    #expect(draft == "Longer source")
}

@Test @MainActor func dynamicFieldSessionsAreIndependentAndRetireWithTheirRecords() {
    let sessions = PlainTextEditorSessions()
    let author = sessions.session(for: "author")
    #expect(sessions.session(for: "author") === author)
    #expect(sessions.session(for: "title") !== author)
    sessions.retain(identifiers: ["title"])
    #expect(sessions.session(for: "author") !== author)
}

@Test @MainActor func actualUndoDispatchNeverFallsThroughAnEmptyTextHistory() {
    let text = PlainTextView(frame: .zero, textContainer: nil)
    text.allowsUndo = true
    var contextualUndos = 0
    var contextualRedos = 0
    let context = EditingUndoContext(canUndo: true, canRedo: true,
                                    undo: { contextualUndos += 1 }, redo: { contextualRedos += 1 })
    EditingRouter.performUndo(responder: text, context: context)
    #expect(contextualUndos == 0)
    text.insertText("Typed text", replacementRange: NSRange(location: 0, length: 0))
    text.breakUndoCoalescing()
    EditingRouter.performUndo(responder: text, context: context)
    #expect(text.string.isEmpty)
    #expect(contextualUndos == 0)
    EditingRouter.performUndo(responder: text, context: context, redo: true)
    #expect(text.string == "Typed text")
    #expect(contextualRedos == 0)
    EditingRouter.performUndo(responder: nil, context: context)
    EditingRouter.performUndo(responder: nil, context: context, redo: true)
    #expect(contextualUndos == 1)
    #expect(contextualRedos == 1)
}

@Test @MainActor func bindingRefreshDoesNotReplaceMarkedText() throws {
    var draft = ""
    let editor = NativePlainTextEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                      session: PlainTextEditorSession(), label: "Source", identifier: "source")
    let scroll = editor.makeNativeScrollView()
    let coordinator = editor.makeCoordinator()
    editor.updateNativeView(scroll, coordinator: coordinator)
    let text = try #require(scroll.documentView as? NSTextView)
    text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
    #expect(text.hasMarkedText())
    draft = "External refresh"
    editor.updateNativeView(scroll, coordinator: coordinator)
    #expect(text.string == "に")
    text.insertText("日本", replacementRange: text.markedRange())
    #expect(draft == "日本")
}

#endif
