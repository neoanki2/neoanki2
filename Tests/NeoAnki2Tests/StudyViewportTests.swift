import AppKit
import NeoAnkiCore
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
        let authored = try #require(items.first { $0["itemTypeId"] as? String == schemaID })
        let fields = try #require(authored["fields"] as? [[String: Any]]).map { field in
            let value = try #require(field["value"] as? [String: Any])
            let fieldID = try #require(field["fieldId"] as? String)
            return FieldValue(fieldID: try #require(UUID(uuidString: fieldID)),
                              value: .text(try #require(value["text"] as? String)))
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
