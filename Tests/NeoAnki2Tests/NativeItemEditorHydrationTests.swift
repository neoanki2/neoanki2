import AppKit
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI
import Testing
@testable import NeoAnki2

/// The actual NSViewRepresentable lifecycle, with no window, app launch, or
/// production database. A passing draft test alone cannot verify native text.
@Suite @MainActor struct NativeItemEditorHydrationTests {
    private final class Box {
        var spans: [Span]
        var selection = RichTextEditing.SelectionState.empty
        var writes = 0
        init(_ spans: [Span]) { self.spans = spans }
    }

    private func editor(_ box: Box, id: String = "field") -> RichTextEditorRepresentable {
        .init(label: id, spans: Binding(get: { box.spans }, set: { box.spans = $0; box.writes += 1 }),
              accessibilityIdentifier: id, textViewHolder: TextViewHolder(), isFocused: nil,
              selectionFormatting: Binding(get: { box.selection }, set: { box.selection = $0 }))
    }

    private func redInk(in scroll: NSScrollView) throws -> (width: Int, height: Int, ink: Int) {
        // Capture an equal-size viewport, never the document's variable bounds.
        // No layoutManager access: that getter can force TextKit compatibility.
        let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var ink = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            let alpha = Int(bytes[offset + 3])
            if red > green + 30, red > blue + 30, alpha > 100 { ink += 1 }
        }
        return (image.width, image.height, ink)
    }

    @Test(arguments: [CGFloat(320), 700], [false, true])
    func nativeEditorDrawsGlyphsInsideViewport(width: CGFloat, hydrateLater: Bool) throws {
        for dark in [false, true] {
            let content = [Span("Який міст? 🧠 e\u{301}\nміст Метро\n" + String(repeating: "Довгий рядок ", count: 80), textColor: .red)]
            let box = Box(hydrateLater ? [] : content)
            let view = editor(box)
            let coordinator = view.makeCoordinator()
            let scroll = view.makeNSView(coordinator: coordinator)
            scroll.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 180)
            scroll.tile()
            scroll.layoutSubtreeIfNeeded()
            let native = try #require(scroll.documentView as? NSTextView)
            #expect(native.isVerticallyResizable && native.autoresizingMask.contains(.width)
                    && native.textContainer?.widthTracksTextView == true, "EDITOR_NATIVE_LAYOUT: shared document sizing must remain active")
            if hydrateLater {
                box.spans = content
                view.updateNSView(scroll, coordinator: coordinator)
            }
            let emptyBox = Box([])
            let emptyView = editor(emptyBox)
            let blank = emptyView.makeNSView(coordinator: emptyView.makeCoordinator())
            blank.appearance = scroll.appearance
            blank.frame = scroll.frame
            blank.tile()
            blank.layoutSubtreeIfNeeded()
            for viewportWidth in [width, width == 320 ? 700 : 320] {
                for viewport in [scroll, blank] {
                    viewport.frame.size.width = viewportWidth
                    viewport.tile()
                    viewport.layoutSubtreeIfNeeded()
                }
                let empty = try redInk(in: blank)
                let rendered = try redInk(in: scroll)
                #expect(rendered.width == empty.width && rendered.height == empty.height)
                #expect(rendered.ink > empty.ink + 10,
                        "EDITOR_VISIBLE_GLYPHS: loaded Unicode text must draw foreground ink inside the viewport")
            }
            #expect(native.string == content.map(\.text).joined())
            #expect(box.writes == 0)
            #expect(scroll.window == nil)
        }
    }

    @Test func replacingAnEditorBindingRoutesNativeChangesOnlyToTheNewDraft() throws {
        let old = Box([Span("Old item")]), replacement = Box([Span("Replacement item")])
        let first = editor(old)
        let coordinator = first.makeCoordinator()
        let scroll = first.makeNSView(coordinator: coordinator)
        let second = editor(replacement)
        second.updateNSView(scroll, coordinator: coordinator)
        let native = try #require(scroll.documentView as? NSTextView)
        native.textStorage?.setAttributedString(SpanFormatting.attributedString(from: [Span("User correction")]))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: native))
        #expect(replacement.spans == [Span("User correction")], "EDITOR_BINDING_TARGET: native edits must reach the current draft")
        #expect(old.spans == [Span("Old item")])
        #expect(old.writes == 0)
    }

    @Test(arguments: [CGFloat(320), 700], [false, true])
    func nativeEditorLaysOutVisibleGlyphsAfterLoadingAndResizing(width: CGFloat, hydrateLater: Bool) throws {
        let answer = "міст Метро"
        let box = Box(hydrateLater ? [] : [Span(answer)])
        let view = editor(box)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeNSView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 180)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        if hydrateLater {
            box.spans = [Span(answer)]
            view.updateNSView(scroll, coordinator: coordinator)
        }
        let native = try #require(scroll.documentView as? NSTextView)
        #expect(native.isVerticallyResizable, "A scrolling editor must grow its document for laid-out text")
        #expect(!native.isHorizontallyResizable, "Long text must wrap inside the editor")
        #expect(native.autoresizingMask.contains(.width), "SwiftUI viewport resizing must resize the document")
        #expect(native.textContainer?.widthTracksTextView == true)
        #expect(native.visibleRect.height > 2 * native.textContainerInset.height,
                "The editor must have room to draw text inside its top and bottom insets")
        let container = try #require(native.textContainer)
        let layout = try #require(native.layoutManager)
        layout.ensureLayout(for: container)
        #expect(native.string == answer)
        #expect(native.frame.width >= scroll.contentSize.width,
                "Loaded text must occupy the scroll viewport rather than a zero-width document")
        #expect(native.visibleRect.width > 2 * native.textContainerInset.width)
        #expect(container.containerSize.width > 2 * container.lineFragmentPadding)
        let used = layout.usedRect(for: container).offsetBy(dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y)
        #expect(!used.isEmpty)
        #expect(used.intersects(native.visibleRect), "Stored and accessible text must have visible glyphs")
    }

    @Test(arguments: ["міст Метро", "Північний міст", "Південний міст", "Дарницький залізнично-автомобільний міст", "міст Патона", "Кудрявський міст"], [false, true])
    func bridgeTextLoadsBeforeOrAfterNativeEditorCreation(answer: String, hydrateLater: Bool) throws {
        let expected = [Span(answer, styles: [.bold])]
        let box = Box(hydrateLater ? [] : expected)
        let view = editor(box)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeNSView(coordinator: coordinator)
        let native = try #require(scroll.documentView as? NSTextView)
        #expect(native.window == nil)
        if hydrateLater {
            box.spans = expected
            view.updateNSView(scroll, coordinator: coordinator)
        }
        #expect(native.string == answer)
        #expect(SpanFormatting.spans(from: native.attributedString()) == expected)
        #expect(box.spans == expected)
        #expect(box.writes == 0, "Loading must never publish an empty native buffer over saved fields")
    }

    @Test func bridgeCardLoadsAllTextFieldsAlongsideItsImage() throws {
        let prompt = FieldDef(name: "Prompt", type: .richText, isRequired: true)
        let answer = FieldDef(name: "Answer", type: .richText, isRequired: true)
        let explanation = FieldDef(name: "Explanation", type: .text)
        let sources = FieldDef(name: "Sources", type: .richText)
        let image = FieldDef(name: "QuestionImage", type: .image)
        let type = ItemType(name: "Київ — візуальна картка", fields: [prompt, answer, explanation, sources, image], templates: [])
        let reference = MediaRef(kind: .image, assetHash: String(repeating: "a", count: 64), fileExtension: "png")
        let item = Item(itemTypeID: type.id, fields: [
            .init(fieldID: prompt.id, value: .rich([Span("Який міст виділено червоним контуром?")])),
            .init(fieldID: answer.id, value: .rich([Span("міст Метро")])),
            .init(fieldID: explanation.id, value: .text("Міст через Дніпро.")),
            .init(fieldID: sources.id, value: .rich([Span("Source", link: "https://example.com/bridge")])),
            .init(fieldID: image.id, value: .media(reference)),
        ])
        let snapshot = ItemEditorState.hydrated(from: item, itemType: type)
        #expect(snapshot.fieldMedia[image.id] == reference)
        #expect(ItemEditorState.canSave(snapshot, itemType: type))
        for field in [prompt, answer, explanation, sources] {
            let expected = try #require(snapshot.fieldSpans[field.id])
            #expect(!expected.isEmpty)
            let box = Box([])
            let view = editor(box, id: field.name)
            let coordinator = view.makeCoordinator()
            let scroll = view.makeNSView(coordinator: coordinator)
            box.spans = expected
            view.updateNSView(scroll, coordinator: coordinator)
            let native = try #require(scroll.documentView as? NSTextView)
            #expect(native.string == expected.map(\.text).joined(), "\(field.name) must not appear empty while the image loads")
            #expect(SpanFormatting.spans(from: native.attributedString()) == expected)
            #expect(box.writes == 0)
        }
    }

    @Test func repeatedNativeUpdatesDoNotEraseTextOrPublishProgrammaticChanges() throws {
        let box = Box([Span("First")])
        let view = editor(box)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeNSView(coordinator: coordinator)
        let native = try #require(scroll.documentView as? NSTextView)
        for text in ["Second 🧠", "", "Третій", "Fourth\nline"] {
            box.spans = text.isEmpty ? [] : [Span(text)]
            view.updateNSView(scroll, coordinator: coordinator)
            view.updateNSView(scroll, coordinator: coordinator)
            #expect(native.string == text)
            #expect(box.writes == 0)
        }
    }

    @Test func swiftUIBindingHydrationReachesNativeTextWithoutAWindow() throws {
        let expected = "Який міст виділено червоним контуром?"
        let box = Box([])
        let view = editor(box)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        hosting.layoutSubtreeIfNeeded()
        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let native = try #require(textViews(in: hosting).first, "The offscreen host must instantiate the real native editor")
        box.spans = [Span(expected)]
        hosting.rootView = editor(box)
        hosting.layoutSubtreeIfNeeded()
        #expect(native.string == expected)
        #expect(native.window == nil)
    }

    @Test func openingTheFullBridgeEditorHydratesTextAlongsideTheImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-editor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await store.bootstrap()
        let prompt = FieldDef(name: "Prompt", type: .richText, isRequired: true)
        let answer = FieldDef(name: "Answer", type: .richText, isRequired: true)
        let explanation = FieldDef(name: "Explanation", type: .text)
        let sources = FieldDef(name: "Sources", type: .richText)
        let evidence = FieldDef(name: "Evidence", type: .text)
        let credit = FieldDef(name: "Credit", type: .text)
        let note = FieldDef(name: "Note", type: .text)
        let image = FieldDef(name: "QuestionImage", type: .image)
        let answerImage = FieldDef(name: "AnswerImage", type: .image)
        let type = ItemType(name: "Київ — візуальна картка", fields: [prompt, answer, explanation, sources, evidence, credit, note, image, answerImage], templates: [
            Template(name: "Name bridge", prompt: Side(slots: [Slot(source: .field(prompt.id))]),
                     answer: Side(slots: [Slot(source: .field(answer.id))]), interaction: .reveal,
                     skill: .init(input: .image, output: .text, operation: .recall)),
        ])
        _ = try await store.createItemType(type)
        let media = try #require(await store.media)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let reference = try await media.ingest(data: png, kind: .image, fileExtension: "png")
        let item = Item(itemTypeID: type.id, fields: [
            .init(fieldID: prompt.id, value: .rich([Span("Який міст виділено червоним контуром?", textSize: .small)])),
            .init(fieldID: answer.id, value: .rich([Span("міст Метро", textSize: .small)])),
            .init(fieldID: explanation.id, value: .text("Міст через Дніпро.")),
            .init(fieldID: sources.id, value: .rich([Span("Джерело", link: "https://example.com/bridge")])),
            .init(fieldID: evidence.id, value: .text("Bridge evidence")),
            .init(fieldID: credit.id, value: .text("Image credit")),
            .init(fieldID: note.id, value: .text("Editor note")),
            .init(fieldID: image.id, value: .media(reference)),
        ])
        _ = try await store.createItem(item)
        let model = ItemsModel(store: store, mediaStore: media)
        await model.load()
        var appeared = false
        let hosting = NSHostingView(rootView: NavigationStack {
            AddItemView(model: model, decksModel: DecksModel(store: store), editingItem: item, editingItemType: type)
                .onAppear { appeared = true }
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 3000)
        hosting.layoutSubtreeIfNeeded()
        try #require(appeared, "The offscreen host must run the real opening lifecycle")
        hosting.layoutSubtreeIfNeeded()
        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let nativeFields = textViews(in: hosting)
        for native in nativeFields where !native.string.isEmpty {
            let viewport = try #require(native.enclosingScrollView)
            #expect(native.frame.width >= viewport.contentSize.width,
                    "\(native.accessibilityIdentifier()) document frame: \(native.frame), viewport: \(viewport.contentSize)")
            #expect(native.visibleRect.height > 2 * native.textContainerInset.height,
                    "\(native.accessibilityIdentifier()) visible rect: \(native.visibleRect), document: \(native.frame)")
        }
        let contents = nativeFields.map(\.string)
        #expect(contents.contains("Який міст виділено червоним контуром?"))
        #expect(contents.contains("міст Метро"))
        for value in ["Міст через Дніпро.", "Джерело", "Bridge evidence", "Image credit", "Editor note"] {
            #expect(contents.contains(value), "The full editor must load \(value)")
        }
        #expect(hosting.window == nil)
        #expect(try await store.fetchItem(id: item.id)?.item == item)
    }
}
