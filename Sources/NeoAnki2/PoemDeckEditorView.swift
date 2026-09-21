import NeoAnkiApplication
import NeoAnkiCore
import PoemDeckBuilder
import SwiftUI

@MainActor
@Observable
final class PoemDeckEditorModel {
    private let library: any LibraryBrowsing & LibraryCoordinatedItemEditing
    private let deckID: UUID
    private let itemTypeID: UUID
    private var records: [PoemDeckItemRecord] = []
    private var previewedSourceText: String?

    var sourceText = ""
    var preview: PoemDeckReconciliationPreview?
    var initialMismatchCount = 0
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

    var canPreview: Bool {
        !isLoading && !isSaving && !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSave: Bool {
        !isLoading
            && !isSaving
            && preview?.hasChanges == true
            && previewedSourceText == sourceText
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
            var loaded: [PoemDeckItemRecord] = []
            loaded.reserveCapacity(summaries.count)
            for summary in summaries where summary.itemTypeID == itemTypeID {
                guard let record = try await library.item(id: summary.id) else {
                    throw PoemDeckReconciliationError.brokenChain
                }
                loaded.append(.init(item: record.item, itemType: record.itemType))
            }
            let snapshot = try PoemDeckReconciler.snapshot(records: loaded)
            records = loaded
            sourceText = snapshot.sourceText
            initialMismatchCount = snapshot.mismatches.count
            preview = nil
            previewedSourceText = nil
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
    }

    func sourceDidChange() {
        guard previewedSourceText != sourceText else { return }
        preview = nil
        previewedSourceText = nil
        errorMessage = nil
    }

    func preparePreview() {
        errorMessage = nil
        do {
            preview = try PoemDeckReconciler.preview(
                sourceText: sourceText,
                records: records
            )
            previewedSourceText = sourceText
        } catch {
            preview = nil
            previewedSourceText = nil
            errorMessage = UserFacingError.message(from: error)
        }
    }

    func save() async throws {
        guard canSave, let preview else { return }
        isSaving = true
        defer { isSaving = false }
        let changedIDs = Set(preview.changes.map(\.itemID))
        let replacements = preview.replacements.filter { changedIDs.contains($0.id) }
        _ = try await library.reconcileItemTypeAndItems(
            expectedItemType: preview.originalItemType,
            updatedItemType: preview.updatedItemType,
            replacements: replacements,
            asOf: .now
        )
    }
}

struct PoemDeckEditorView: View {
    let deckName: String
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var model: PoemDeckEditorModel
    @AccessibilityFocusState private var errorFocused: Bool

    init(
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
        _model = State(initialValue: PoemDeckEditorModel(
            library: library,
            deckID: deckID,
            itemTypeID: itemTypeID
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Loading poem…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editor
                }
            }
            .navigationTitle("Edit Poem")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 620, idealHeight: 760)
        .interactiveDismissDisabled(model.isSaving)
        .task { await model.load() }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section("Canonical source") {
                    Text(deckName)
                        .font(.headline)
                    TextEditor(text: $model.sourceText)
                        .font(.body)
                        .frame(minHeight: 300)
                        .accessibilityLabel("Canonical poem source")
                        .accessibilityHint(
                            "Keep the same lines in the same order. Blank lines mark stanza boundaries."
                        )
                        .accessibilityIdentifier("poemEditorSource")
                        .onChange(of: model.sourceText) { _, _ in model.sourceDidChange() }
                    Text("Keep the line count unchanged. Insert blank lines only where the canonical source has stanza breaks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.initialMismatchCount > 0, model.preview == nil {
                    Section {
                        Label(
                            "NeoAnki found \(model.initialMismatchCount) inconsistent stored context \(model.initialMismatchCount == 1 ? "copy" : "copies"). Preview to repair them from the answers above.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .accessibilityIdentifier("poemEditorIntegrityWarning")
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityFocused($errorFocused)
                            .accessibilityIdentifier("poemEditorError")
                    }
                }

                if let preview = model.preview {
                    Section("Preview") {
                        LabeledContent("Lines", value: "\(preview.poem.lines.count)")
                        LabeledContent("Stanzas", value: "\(preview.poem.stanzas.count)")
                        LabeledContent("Cards changed", value: "\(preview.changes.count)")
                        if preview.repairedMismatchCount > 0 {
                            LabeledContent(
                                "Context inconsistencies repaired",
                                value: "\(preview.repairedMismatchCount)"
                            )
                        }
                        if preview.changes.isEmpty {
                            Text("The stored sequence already matches this source.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preview.changes) { change in
                                PoemReconciliationChangeView(change: change)
                            }
                        }
                    }
                    .accessibilityIdentifier("poemEditorPreview")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                if model.isSaving {
                    ProgressView("Saving…")
                        .controlSize(.small)
                }
                Spacer()
                Button("Preview Changes") {
                    model.preparePreview()
                    errorFocused = model.errorMessage != nil
                }
                .disabled(!model.canPreview)
                .accessibilityIdentifier("poemEditorPreviewButton")

                Button("Save Changes") {
                    Task {
                        do {
                            try await model.save()
                            onSaved()
                        } catch {
                            model.errorMessage = UserFacingError.message(from: error)
                            errorFocused = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .accessibilityIdentifier("poemEditorSave")
            }
            .padding()
        }
    }
}

private struct PoemReconciliationChangeView: View {
    let change: PoemDeckReconciliationChange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if change.oldPrompt != change.newPrompt {
                changePair(label: "Prompt", old: change.oldPrompt, new: change.newPrompt)
            }
            if change.oldAnswer != change.newAnswer {
                changePair(label: "Answer", old: change.oldAnswer, new: change.newAnswer)
            }
            if change.addsStanzaBreak {
                Label("Add revealed stanza break", systemImage: "text.append")
            } else if change.removesStanzaBreak {
                Label("Remove revealed stanza break", systemImage: "text.badge.minus")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func changePair(label: String, old: String, new: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("− \(old)").foregroundStyle(.secondary)
            Text("+ \(new)")
        }
        .textSelection(.enabled)
    }
}
