#if os(iOS)
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiSharedUI
import SwiftUI
import UIKit

/// Explicit Simulator-only fixture entry point. Uses the real shared editor,
/// SQLite commit, card generation, and study session without a photo-library
/// permission or nondeterministic system file picker.
public struct MobileImageOcclusionTestHost: View {
    @Bindable var model: LibraryFeatureModel
    @State private var image: ImageOcclusionContent?
    @State private var saved: ImageOcclusionContent?
    @State private var type: ItemType?
    @State private var itemID: UUID?
    @State private var editing = false
    @State private var error: String?

    public init(model: LibraryFeatureModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if image != nil {
                    Button(saved == nil ? "Create Occlusion" : "Edit Occlusion") { editing = true }
                        .accessibilityIdentifier("occlusion-fixture-edit")
                    Text("\(saved?.groups.count ?? 0) saved cards").accessibilityIdentifier("occlusion-fixture-count")
                    if saved != nil {
                        Button("Study Occlusion") { Task { await model.beginStudy(scope: .allDecks, title: "Image Occlusion") } }
                            .accessibilityIdentifier("occlusion-fixture-study")
                    }
                } else { ProgressView("Preparing diagram…") }
                if let error { Text(error) }
            }.padding().navigationTitle("Occlusion Fixture")
        }
        .fullScreenCover(isPresented: $editing) {
            if let initial = saved ?? image {
                ImageOcclusionEditor(initial: initial, mediaStore: model.mediaStore) { updated in
                    Task { await commit(updated) }
                } onCancel: { editing = false }
            }
        }
        .fullScreenCover(item: $model.activeStudy) { session in
            StudySessionView(session: session, model: model)
        }
        .task {
            await model.bootstrap()
            do {
                let candidate = try ItemTypeStudioDraft.newImageOcclusion().candidateItemType()
                _ = try await model.library.createItemType(candidate)
                type = candidate
                let renderer = UIGraphicsImageRenderer(size: .init(width: 400, height: 300))
                let data = renderer.pngData { context in
                    UIColor.white.setFill(); context.fill(.init(x: 0, y: 0, width: 400, height: 300))
                    ("Diagram A     Diagram B" as NSString).draw(at: .init(x: 40, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
                }
                let ref = try await model.library.reserveMedia(data: data, kind: .image, altText: "Two diagram labels", asOf: .now).reference
                image = .init(image: ref)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func commit(_ content: ImageOcclusionContent) async {
        guard let type else { return }
        var content = content
        if !content.masks.isEmpty { content.masks[0].answerText = "Region answer" }
        let id = itemID ?? UUID()
        let item = Item(id: id, itemTypeID: type.id, fields: [.init(fieldID: type.fields[0].id, value: .imageOcclusion(content))])
        do {
            if itemID == nil { _ = try await model.library.createItem(item, asOf: .now) }
            else { _ = try await model.library.updateItem(item, asOf: .now) }
            itemID = id; saved = content; editing = false
            await model.refresh()
        } catch { self.error = error.localizedDescription }
    }
}
#endif
