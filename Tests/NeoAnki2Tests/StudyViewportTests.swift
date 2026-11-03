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
