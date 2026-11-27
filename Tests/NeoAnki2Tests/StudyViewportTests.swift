import AppKit
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiSharedUI
import SwiftUI
import Testing
@testable import NeoAnki2

private struct StudyControlProbe: NSViewRepresentable {
    let name: String
    let height: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: height)
    }
}

@MainActor
private func descendant(_ name: String, in view: NSView) -> NSView? {
    if view.identifier?.rawValue == name { return view }
    return view.subviews.lazy.compactMap { descendant(name, in: $0) }.first
}

@Test @MainActor func oversizedStudyContentCannotDisplaceResponseOrFooter() throws {
    // Offscreen hosting only: no application window, desktop automation, or
    // user's library is involved. Measure actual placed native controls.
    for size in [CGSize(width: 960, height: 640), CGSize(width: 800, height: 500)] {
        let host = NSHostingView(rootView:
            AdaptiveStudyStage(layout: .focus) {
                StudyStageContent(spacing: 16) {
                    Color.clear.frame(minHeight: 2_400)
                } response: {
                    StudyControlProbe(name: "response", height: 84)
                }
            } footer: {
                StudyControlProbe(name: "footer", height: 60)
            }
        )
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        for name in ["response", "footer"] {
            let view = try #require(descendant(name, in: host))
            let frame = host.convert(view.bounds, from: view)
            #expect(frame.minY >= -1)
            #expect(frame.maxY <= size.height + 1)
            #expect(frame.height >= (name == "response" ? 84 : 60))
        }
    }
}

@Test func concealedExplanationsHaveNoPreAnswerPlaceholderRows() {
    let question = ResolvedTemplateComponent(id: UUID(), region: .primary, purpose: .question,
        value: .text("The box of cables is heavy."), presentation: Presentation())
    let explanation = ResolvedTemplateComponent(id: UUID(), region: .supporting, purpose: .supporting,
        value: .text("Box is the main noun."), presentation: Presentation(reveal: .hiddenUntilAnswer))
    let descriptor = CardWireframeDescriptor.descriptor(for: .focus)
    #expect(descriptor.renderedComponents(from: [question, explanation], answerRevealed: false).map(\.id) == [question.id])
    #expect(descriptor.renderedComponents(from: [question, explanation], answerRevealed: true).map(\.id) == [question.id, explanation.id])
}

@Test("A revealed card with an image and long notes scrolls without moving the grades")
@MainActor func studyMixedAnswerScrollsAtFullHeight() throws {
    let symbol = UUID(), details = UUID(), diagram = UUID()
    let template = Template(name: "Character", layout: .focus, components: [
        TemplateComponent(region: .primary, purpose: .question, source: .field(symbol)),
        TemplateComponent(region: .supporting, purpose: .supporting, source: .field(details),
                          presentation: Presentation(reveal: .hiddenUntilAnswer)),
        TemplateComponent(region: .media, purpose: .supporting, source: .field(diagram),
                          presentation: Presentation(reveal: .hiddenUntilAnswer)),
    ], interaction: .reveal, skill: Skill(input: .text, output: .text, operation: .recall))
    let notes = (1 ... 30).map { "Line \($0) of the revealed explanation." }.joined(separator: "\n")
    let item = Item(itemTypeID: UUID(), fields: [
        FieldValue(fieldID: symbol, value: .text("丶", lang: "ja")),
        FieldValue(fieldID: details, value: .rich([Span("Meaning\n", styles: [.bold]), Span(notes)])),
        FieldValue(fieldID: diagram, value: .media(MediaRef(
            kind: .image, assetHash: String(repeating: "a", count: 64), fileExtension: "png"
        ))),
    ])

    func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    for revealed in [false, true] {
        let host = NSHostingView(rootView:
            AdaptiveStudyStage(layout: .focus) {
                StudyStageContent(spacing: 16) {
                    StudyCompositionView(template: template, item: item, isAnswerRevealed: revealed,
                                         mediaStore: nil, clozeGroup: nil)
                } response: { EmptyView() }
            } footer: { StudyControlProbe(name: "footer", height: 60) }
        )
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        host.layoutSubtreeIfNeeded()
        let footer = try #require(descendant("footer", in: host))
        let footerFrame = host.convert(footer.bounds, from: footer)
        #expect(footerFrame.minY >= -1 && footerFrame.maxY <= host.bounds.height + 1)
        if revealed {
            let scroll = try #require(findScrollView(in: host))
            #expect(scroll.documentVisibleRect.height > 0)
        } else {
            #expect(findScrollView(in: host) == nil)
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NEOANKI_LAYOUT_FIXTURES"] != nil))
@MainActor func realAuthoredCardsRenderOffscreenBeforeAndAfterReveal() throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEOANKI_LAYOUT_FIXTURES"]))
    let schemas = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("item-types.json"))) as? [[String: Any]])
    let lines = try String(contentsOf: directory.appendingPathComponent("items.jsonl"), encoding: .utf8).split(separator: "\n")
    let items = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    let output = directory.appendingPathComponent("offscreen-card-layouts")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for schema in schemas {
        let schemaID = try #require(schema["id"] as? String)
        let candidates = items.filter { $0["itemTypeId"] as? String == schemaID }
        let authored = try #require(candidates.first { item in
            (item["fields"] as? [[String: Any]])?.contains { field in
                (field["value"] as? [String: Any])?["type"] as? String == "cloze"
            } == true
        } ?? candidates.first)
        let fields = try #require(authored["fields"] as? [[String: Any]]).map { field in
            let value = try #require(field["value"] as? [String: Any])
            let fieldID = try #require(field["fieldId"] as? String)
            let content: ContentValue
            switch value["type"] as? String {
            case "text": content = .text(try #require(value["text"] as? String))
            case "empty": content = .empty
            case "cloze":
                let blanks = try #require(value["blanks"] as? [[String: Any]]).map { blank in
                    ClozeSpan(group: try #require(blank["group"] as? Int),
                              start: try #require(blank["start"] as? Int),
                              length: try #require(blank["length"] as? Int))
                }
                content = .cloze(try #require(value["text"] as? String), blanks: blanks)
            default: throw CocoaError(.coderInvalidValue)
            }
            return FieldValue(fieldID: try #require(UUID(uuidString: fieldID)), value: content)
        }
        let definition = try #require((schema["templates"] as? [[String: Any]])?.first)
        let components = try #require(definition["components"] as? [[String: Any]]).map { part in
            let source = try #require(part["source"] as? [String: Any])
            let presentation = try #require(part["presentation"] as? [String: Any])
            let region = try #require(part["region"] as? String)
            let purpose = try #require(part["purpose"] as? String)
            let sourceID = try #require(source["fieldId"] as? String)
            let reveal = try #require(presentation["reveal"] as? String)
            return TemplateComponent(
                region: try #require(ComponentRegion(rawValue: region)),
                purpose: try #require(ComponentPurpose(rawValue: purpose)),
                source: .field(try #require(UUID(uuidString: sourceID))),
                presentation: Presentation(reveal: try #require(RevealMode(rawValue: reveal))))
        }
        let template = Template(name: "Fixture", layout: .focus, components: components, interaction: .type,
                                skill: Skill(input: .text, output: .freeResponse, operation: .recall))
        let item = Item(itemTypeID: try #require(UUID(uuidString: schemaID)), fields: fields)
        let operation = try #require(definition["name"] as? String)
        for revealed in [false, true] {
            for height in [280, 420] {
                let renderer = ImageRenderer(content:
                    StudyCompositionView(template: template, item: item, isAnswerRevealed: revealed,
                                         mediaStore: nil, clozeGroup: nil)
                        .frame(width: 640, height: CGFloat(height))
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, .dark)
                )
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("\(operation)-\(revealed ? "answer" : "question")-\(height).png"))
            }
        }
    }
}

@MainActor
private func paintedTextBounds<V: View>(_ view: V) throws -> CGRect {
    let renderer = ImageRenderer(content: view.foregroundStyle(.white))
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let bounds = try pixels.withUnsafeMutableBytes { buffer -> CGRect in
        let context = try #require(CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where buffer[(y * width + x) * 4 + 3] > 16 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        #expect(maxX >= minX && maxY >= minY, "The study text must actually render")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    return bounds
}

@Test("Portrait and landscape diagrams aspect-fit every study layout with controls visible")
@MainActor func studyDiagramsFitAvailableHeight() throws {
    // Use a synchronous bitmap with the same resizable/aspect-fit rendering as
    // OcclusionImage. This exercises the real viewport and wireframe without
    // depending on an asynchronous media load or opening an application window.
    for imageSize in [CGSize(width: 200, height: 800), CGSize(width: 800, height: 200)] {
        let bitmap = try #require(CGContext(data: nil, width: Int(imageSize.width), height: Int(imageSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.red.cgColor)
        bitmap.fill(CGRect(origin: .zero, size: imageSize))
        let image = try #require(bitmap.makeImage())
        let component = ResolvedTemplateComponent(id: UUID(), region: .media, purpose: .question,
            value: .media(MediaRef(kind: .image, assetHash: String(repeating: "a", count: 64), fileExtension: "png")),
            presentation: Presentation())
        for layout in CardLayoutID.allCases {
            for size in [CGSize(width: 960, height: 640), CGSize(width: 800, height: 500), CGSize(width: 500, height: 400)] {
                let view = AdaptiveStudyStage(layout: layout) {
                    StudyStageContent(spacing: 16) {
                        StudyCardViewport(fitsMedia: true) {
                            CardWireframeView(layout: layout, components: [component], isAnswerRevealed: false) { _, _ in
                                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: 820)
                        .padding(.horizontal, 20).padding(.vertical, 24)
                    } response: { Color.blue.frame(height: 44) }
                } footer: { Color.green.frame(height: 60) }
                let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
                let rendered = try #require(renderer.cgImage)
                var pixels = [UInt8](repeating: 0, count: rendered.width * rendered.height * 4)
                let bounds = try pixels.withUnsafeMutableBytes { buffer -> CGRect in
                    let context = try #require(CGContext(data: buffer.baseAddress, width: rendered.width, height: rendered.height,
                        bitsPerComponent: 8, bytesPerRow: rendered.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
                    var minX = rendered.width, minY = rendered.height, maxX = -1, maxY = -1
                    for y in 0 ..< rendered.height {
                        for x in 0 ..< rendered.width {
                            let offset = (y * rendered.width + x) * 4
                            if buffer[offset] > 200 && buffer[offset + 1] < 40 && buffer[offset + 2] < 40 {
                                minX = min(minX, x); maxX = max(maxX, x)
                                minY = min(minY, y); maxY = max(maxY, y)
                            }
                        }
                    }
                    return CGRect(x: minX, y: minY, width: max(0, maxX - minX + 1), height: max(0, maxY - minY + 1))
                }
                #expect(bounds.height >= 40, "The diagram must render in \(layout) at \(size)")
                #expect(abs(bounds.width - bounds.height * imageSize.width / imageSize.height) <= 4,
                        "The complete diagram must retain its aspect ratio in \(layout) at \(size)")
                // The bitmap rows run from top to bottom. Keep the complete
                // diagram above the fixed response/footer and inside padding.
                #expect(bounds.minY >= 23)
                #expect(bounds.maxY <= size.height - 44 - 60 - 16 - 23)
            }
        }
    }
}

@Test("Poetry prompts and revealed answers retain the native study type sizes")
@MainActor func studyTextRetainsReadableQuestionAndAnswerFonts() throws {
    // Exercise the real composition, not a duplicated font-selection helper.
    // Comparing painted glyph bounds catches font(nil) resetting inheritance.
    let line = "І день і ніч плачу"
    for (region, purpose, font) in [
        (ComponentRegion.primary, ComponentPurpose.question, DesignSystem.Typography.cardPrompt),
        (.secondary, .expectedAnswer, DesignSystem.Typography.cardAnswer),
    ] {
        let field = UUID()
        let template = Template(name: "Poetry", layout: .focus, components: [
            TemplateComponent(region: region, purpose: purpose, source: .field(field))
        ], interaction: .reveal, skill: Skill(input: .text, output: .text, operation: .recall))
        let item = Item(itemTypeID: UUID(), fields: [FieldValue(fieldID: field, value: .text(line))])
        let actual = try paintedTextBounds(
            StudyCompositionView(template: template, item: item, isAnswerRevealed: true,
                                 mediaStore: nil, clozeGroup: nil)
                .frame(width: 960, height: 640)
        )
        let expected = try paintedTextBounds(Text(line).font(font).frame(width: 960, height: 640))
        #expect(abs(actual.width - expected.width) <= 2)
        #expect(abs(actual.height - expected.height) <= 2)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NEOANKI_LAYOUT_FIXTURES"] != nil))
@MainActor func poetryCardRendersOffscreenBeforeAndAfterReveal() throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEOANKI_LAYOUT_FIXTURES"]))
        .appendingPathComponent("offscreen-poetry-layouts")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let attribution = UUID(), front = UUID(), back = UUID()
    let template = Template(name: "Poem Line", layout: .focus, components: [
        TemplateComponent(region: .label, purpose: .supporting, source: .field(attribution)),
        TemplateComponent(region: .primary, purpose: .question, source: .field(front)),
        TemplateComponent(region: .secondary, purpose: .expectedAnswer, source: .field(back),
                          presentation: Presentation(reveal: .hiddenUntilAnswer)),
    ], interaction: .reveal, skill: Skill(input: .text, output: .text, operation: .recall))
    // The user's supplied example; never touches the poetry deck or its grades.
    let item = Item(itemTypeID: UUID(), fields: [
        FieldValue(fieldID: attribution, value: .text("І мертвим, і живим, і ненарожденним землякам моїм в Україні і не в Україні моє дружнєє посланіє · Тарас Шевченко")),
        FieldValue(fieldID: front, value: .text("І все спочиває.\nТільки я, мов окаянний,")),
        FieldValue(fieldID: back, value: .text("І день і ніч плачу")),
    ])
    for size in [CGSize(width: 960, height: 640), CGSize(width: 800, height: 500)] {
        for revealed in [false, true] {
            let renderer = ImageRenderer(content:
                AdaptiveStudyStage(layout: .focus) {
                    StudyStageContent(spacing: 16) {
                        StudyCompositionView(template: template, item: item, isAnswerRevealed: revealed,
                                             mediaStore: nil, clozeGroup: nil)
                    } response: { EmptyView() }
                } footer: {
                    HStack {
                        ForEach(["Again (1)", "Hard (2)", "Good (3)", "Easy (4)"], id: \.self) { title in
                            Button(title) {}
                        }
                    }.padding(16)
                }
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            )
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("poetry-\(revealed ? "answer" : "question")-\(Int(size.width))x\(Int(size.height)).png"))
        }
    }
}

@Test("The original grammar prompt fits with full-sized text and visible typed controls")
@MainActor func originalGrammarCardKeepsTextAndControlsInsideViewport() throws {
    let prompt = UUID()
    let template = Template(name: "Original grammar card", layout: .focus, components: [
        TemplateComponent(region: .primary, purpose: .question, source: .field(prompt)),
    ], interaction: .type, skill: Skill(input: .text, output: .freeResponse, operation: .recall))
    let text = "Read the sentence. Type the head noun of its subject noun phrase.\n\nThe box of cables is heavy."
    let item = Item(itemTypeID: UUID(), fields: [FieldValue(fieldID: prompt, value: .text(text))])
    for size in [CGSize(width: 960, height: 640), CGSize(width: 800, height: 500)] {
        let composition = StudyCompositionView(template: template, item: item,
                                              isAnswerRevealed: false, mediaStore: nil, clozeGroup: nil)
        let stage = AdaptiveStudyStage(layout: .focus) {
            StudyStageContent(spacing: 16) {
                composition
            } response: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your answer")
                    TextField("Type your answer", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                    Text("Press Return to check. You’ll still choose your own grade.")
                }.frame(maxWidth: 640).padding(.horizontal, 20)
            }
        } footer: {
            StudyControlProbe(name: "footer", height: 60)
        }
        let host = NSHostingView(rootView: stage)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        func findTextField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap(findTextField).first
        }
        let field = try #require(findTextField(host))
        for view in [field, try #require(descendant("footer", in: host))] {
            let bounds = host.convert(view.bounds, from: view)
            #expect(bounds.minY >= -1 && bounds.maxY <= size.height + 1)
            #expect(bounds.height > 16)
        }
        // Check the original long prompt at its normal semantic study size,
        // with only the space actually left above the response and footer.
        let available = CGSize(width: size.width, height: size.height - 170)
        let actual = try paintedTextBounds(composition.frame(width: available.width, height: available.height))
        let reference = try paintedTextBounds(
            Text(text).font(DesignSystem.Typography.cardPrompt).multilineTextAlignment(.center)
                .frame(maxWidth: min(820, size.width - 40))
                .frame(width: available.width, height: available.height)
        )
        #expect(abs(actual.width - reference.width) <= 2)
        #expect(abs(actual.height - reference.height) <= 2)
    }
}

@Test @MainActor func structuredGrammarCardRendersPromptAndFeedbackTogether() async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-layout-\(UUID())")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let exercise = StudyExercise(mode: .target, parts: ["Then I opened ", " file from another folder."],
                                targets: [.init(choices: ["a", "an", "the"], allowsOmission: true)], answers: [["a"]])
    let fixture = try await structuredGrammarFixture(exercise: exercise, directory: scratch)
    let model = fixture.model
    let card = fixture.card
    let canvasSizes = [CGSize(width: 950, height: 570), CGSize(width: 620, height: 440)]
    for size in canvasSizes {
        let host = NSHostingView(rootView: grammarCanvas(card: card, exercise: exercise, model: model, size: size))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let field = try #require(grammarNativeField(in: host))
        let bounds = host.convert(field.bounds, from: field)
        #expect(bounds.minX > max(12, (size.width - 560) / 2 - 4))
        #expect(bounds.width < 240)
        #expect(bounds.midY > size.height * 0.2 && bounds.midY < size.height * 0.8)
    }
    try renderGrammarCanvas(card: card, exercise: exercise, model: model, state: "prompt", sizes: canvasSizes)
    model.updateExerciseTarget(0, value: "the")
    model.submitTypedAnswer()
    #expect(model.answerEvaluation == .incorrect)
    #expect(model.reviewResponse == "the")
    try renderGrammarCanvas(card: card, exercise: exercise, model: model, state: "checked", sizes: canvasSizes)
}

@Test @MainActor func structuredRewriteAndChoiceRenderBeforeAndAfterChecking() async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("exercise-layout-\(UUID())")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let exercises = [
        StudyExercise(mode: .rewrite, prompt: "It works.", answers: [["Does it work?"]]),
        StudyExercise(mode: .choose,
                      prompt: "A. It rains here in winter.\nB. It rains here in the winter.",
                      options: [.init(id: "a", label: "Only A"), .init(id: "b", label: "Only B"),
                                .init(id: "both", label: "Both"), .init(id: "neither", label: "Neither")],
                      correctOptionID: "both"),
    ]
    for exercise in exercises {
        let folder = scratch.appendingPathComponent(exercise.mode.rawValue)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await structuredGrammarFixture(exercise: exercise, directory: folder)
        let model = fixture.model
        let sizes = [CGSize(width: 950, height: 570), CGSize(width: 620, height: 440)]
        try renderGrammarCanvas(card: fixture.card, exercise: exercise, model: model,
                                state: exercise.mode.rawValue + "-prompt", sizes: sizes)
        #expect(!model.isAnswerRevealed)
        if exercise.mode == .rewrite {
            model.updateTypedAnswer("Does it work?")
            model.submitTypedAnswer()
        } else {
            model.submitExerciseChoice("both")
        }
        #expect(model.isAnswerRevealed)
        #expect(model.answerEvaluation == .correct)
        try renderGrammarCanvas(card: fixture.card, exercise: exercise, model: model,
                                state: exercise.mode.rawValue + "-checked", sizes: sizes)
    }
}

@MainActor
private func structuredGrammarFixture(exercise: StudyExercise, directory: URL) async throws -> (model: StudyFeatureModel, card: DueCard) {
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let field = FieldDef(name: "Exercise", type: .studyExercise, isRequired: true)
    let cue: String
    let solution: String
    let explanation: String
    switch exercise.mode {
    case .target:
        cue = "A different file"
        solution = "Then I opened a file from another folder."
        explanation = "Introduce a new, unspecified file with a."
    case .rewrite:
        cue = "Yes/no question"
        solution = "Does it work?"
        explanation = "Use does and the base form of the main verb."
    case .choose:
        cue = "Standard American English"
        solution = "Both"
        explanation = "Both versions describe a recurring season."
    }
    let template = Template(name: exercise.mode.title, layout: .split, components: [
        .init(region: .label, purpose: .supporting, source: .literal(cue)),
        .init(region: .primary, purpose: .question, source: .field(field.id)),
        .init(region: .secondary, purpose: .expectedAnswer, source: .literal(solution),
              presentation: .init(reveal: .hiddenUntilAnswer)),
        .init(region: .supporting, purpose: .supporting, source: .literal(explanation),
              presentation: .init(reveal: .hiddenUntilAnswer)),
    ], interaction: exercise.mode == .choose ? .choose : .type,
       skill: .init(input: .text, output: .freeResponse, operation: .apply))
    let type = ItemType(name: "Grammar layout fixture", fields: [field], templates: [template])
    _ = try await store.createItemType(type)
    _ = try await store.createItem(Item(itemTypeID: type.id, fields: [.init(fieldID: field.id, value: .studyExercise(exercise))]))
    let model = StudyFeatureModel(library: SQLiteLibraryRepository(store: store), scope: .allDecks, title: "Grammar")
    await model.start()
    return (model, try #require(model.currentCard))
}

@MainActor
private func grammarCanvas(card: DueCard, exercise: StudyExercise, model: StudyFeatureModel, size: CGSize) -> some View {
    AdaptiveStudyStage(layout: .split, showsFooter: model.isAnswerRevealed) {
        GeometryReader { viewport in
            ScrollView {
                StudyExerciseCard(card: card, exercise: exercise, model: model)
                    .padding(.top, min(72, viewport.size.height * 0.12))
                    .frame(minHeight: viewport.size.height, alignment: .top)
            }
        }
    } footer: {
        HStack {
            ForEach(["Again (1)", "Hard (2)", "Good (3)", "Easy (4)"], id: \.self) { title in
                Button(title) {}
            }
        }
        .padding(16)
    }
    .frame(width: size.width, height: size.height)
}

@MainActor
private func grammarNativeField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { grammarNativeField(in: $0) }.first
}

@MainActor
private func renderGrammarCanvas(card: DueCard, exercise: StudyExercise, model: StudyFeatureModel, state: String, sizes: [CGSize]) throws {
    guard let path = ProcessInfo.processInfo.environment["NEOANKI_GRAMMAR_LAYOUT_IMAGES"] else { return }
    let directory = URL(fileURLWithPath: path)
    for size in sizes {
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: grammarCanvas(card: card, exercise: exercise, model: model, size: size)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("grammar-\(state)-\(Int(size.width))-\(scheme).png"))
        }
    }
}
