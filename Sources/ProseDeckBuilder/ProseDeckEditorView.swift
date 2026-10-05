import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

@MainActor
@Observable
final class ProseDeckEditorModel {
    private let library: any LibraryBrowsing & LibraryCoordinatedItemEditing
    private let deckID: UUID
    private let itemTypeID: UUID
    private var records: [ProseDeckItemRecord] = []

    var initialSourceText = ""
    var sourceText = ""
    var units: [ProseUnit] = []
    var preview: ProseDeckEditPreview?
    var isLoading = true
    var isSaving = false
    var errorMessage: String?

    init(
        library: any LibraryBrowsing & LibraryCoordinatedItemEditing,
        deckID: UUID,
        itemTypeID: UUID
    ) {
        self.library = library
        self.deckID = deckID
        self.itemTypeID = itemTypeID
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let summaries = try await library.items(
                scope: .deck(deckID, includeDescendants: false),
                sort: .createdAscending,
                search: ""
            )
            guard summaries.allSatisfy({ $0.itemTypeID == itemTypeID }) else {
                throw ProseDeckEditError.mixedContent
            }
            var loaded: [ProseDeckItemRecord] = []
            loaded.reserveCapacity(summaries.count)
            for summary in summaries {
                guard let record = try await library.item(id: summary.id) else {
                    throw ProseDeckEditError.mixedContent
                }
                loaded.append(.init(item: record.item, itemType: record.itemType))
            }
            let snapshot = try ProseDeckReconciler.snapshot(records: loaded)
            records = loaded
            sourceText = snapshot.sourceText
            initialSourceText = snapshot.sourceText
            units = snapshot.units
            preview = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func preparePreview() -> Bool {
        units = ProseText.parse(sourceText, preserving: units)
        return refreshPreview()
    }

    @discardableResult
    func refreshPreview() -> Bool {
        errorMessage = nil
        do {
            preview = try ProseDeckReconciler.preview(
                units: units,
                records: records,
                deckID: deckID
            )
            return true
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func save() async throws {
        guard let preview, preview.hasChanges, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        _ = try await library.reconcileOrderedDeckItems(
            preview.operations,
            order: preview.order,
            asOf: .now
        )
    }
}

public struct ProseDeckEditorView: View {
    private let deckName: String
    private let onSaved: () -> Void
    private let onCancel: () -> Void
    @State private var model: ProseDeckEditorModel
    @State private var isPreviewing = false
    @State private var confirmsDiscard = false

    public init(
        library: any LibraryBrowsing & LibraryCoordinatedItemEditing,
        deckID: UUID,
        itemTypeID: UUID,
        deckName: String,
        onSaved: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.deckName = deckName
        self.onSaved = onSaved
        self.onCancel = onCancel
        _model = State(initialValue: ProseDeckEditorModel(
            library: library,
            deckID: deckID,
            itemTypeID: itemTypeID
        ))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.isLoading {
                    ProgressView("Loading passage…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isPreviewing {
                    ProseUnitReviewView(
                        units: $model.units,
                        newCardIndices: Set(model.preview?.newCardIndices ?? []),
                        retiredCards: model.preview?.retiredCards ?? []
                    )
                        .onChange(of: model.units) { _, _ in model.refreshPreview() }
                        .disabled(model.isSaving)
                } else {
                    Form {
                        Section("Canonical source") {
                            Text(deckName).font(.headline)
                            TextEditor(text: $model.sourceText)
                                .font(.body)
                                .frame(minHeight: 300)
                                .accessibilityLabel("Canonical prose source")
                                .accessibilityIdentifier("proseEditorSource")
                            Text("Blank lines mark paragraphs. Review the cards before saving.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                }

                if let preview = model.preview, isPreviewing {
                    Text(
                        "\(preview.addedCount) new · \(preview.retiredCount) retired · \(preview.changedPromptCount) changed cues · \(preview.retainedCount) retained"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .accessibilityIdentifier("proseEditorChanges")
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding()
                        .accessibilityIdentifier("proseEditorError")
                }
                #if os(macOS)
                Divider()
                HStack {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if isPreviewing {
                        Button("Edit Text") {
                            model.sourceText = ProseText.source(from: model.units)
                            isPreviewing = false
                        }
                        Button("Save Changes") {
                            Task {
                                do {
                                    try await model.save()
                                    onSaved()
                                } catch {
                                    model.errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.preview?.hasChanges != true || model.isSaving)
                        .accessibilityIdentifier("proseEditorSave")
                    } else {
                        Button("Preview Changes") {
                            isPreviewing = model.preparePreview()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isLoading || model.isSaving)
                        .accessibilityIdentifier("proseEditorPreview")
                    }
                }
                .padding()
                #endif
            }
            .navigationTitle(isPreviewing ? "Review Prose Changes" : "Edit Prose")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if hasChanges { confirmsDiscard = true } else { onCancel() } }.disabled(model.isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    if isPreviewing {
                        Button("Save") { Task { do { try await model.save(); onSaved() } catch { model.errorMessage = error.localizedDescription } } }
                            .disabled(model.preview?.hasChanges != true || model.isSaving).accessibilityIdentifier("proseEditorSave")
                    } else {
                        Button("Preview") { isPreviewing = model.preparePreview() }.disabled(model.isLoading || model.isSaving).accessibilityIdentifier("proseEditorPreview")
                    }
                }
                if isPreviewing { ToolbarItem(placement: .topBarLeading) { Button("Edit Text") { model.sourceText = ProseText.source(from: model.units); isPreviewing = false }.disabled(model.isSaving) } }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 620, idealHeight: 760)
        #endif
        .interactiveDismissDisabled(model.isSaving || isMobileDirty)
        .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard) { Button("Discard Changes", role: .destructive, action: onCancel); Button("Keep Editing", role: .cancel) {} }
        .task { await model.load() }
    }

    private var isMobileDirty: Bool {
        #if os(iOS)
        hasChanges
        #else
        false
        #endif
    }
    private var hasChanges: Bool { model.sourceText != model.initialSourceText || model.preview?.hasChanges == true }
}
