import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

@MainActor
@Observable
final class PoemDeckEditorModel {
    private let library: any LibraryBrowsing & LibraryCoordinatedItemEditing
    private let deckID: UUID
    private let itemTypeID: UUID
    private let deckName: String
    private var records: [PoemDeckItemRecord] = []
    private var previewedSourceText: String?

    var initialSourceText = ""
    var sourceText = ""
    var preview: PoemDeckReconciliationPreview?
    var initialMismatchCount = 0
    var isLoading = true
    var isSaving = false
    var errorMessage: String?

    init(
        library: any LibraryBrowsing & LibraryCoordinatedItemEditing,
        deckID: UUID,
        itemTypeID: UUID,
        deckName: String
    ) {
        self.library = library
        self.deckID = deckID
        self.itemTypeID = itemTypeID
        self.deckName = deckName
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
            guard summaries.allSatisfy({ $0.itemTypeID == itemTypeID }) else {
                throw PoemDeckReconciliationError.mixedItemTypes
            }
            var loaded: [PoemDeckItemRecord] = []
            loaded.reserveCapacity(summaries.count)
            for summary in summaries {
                guard let record = try await library.item(id: summary.id) else {
                    throw PoemDeckReconciliationError.brokenChain
                }
                loaded.append(.init(
                    item: record.item,
                    itemType: record.itemType,
                    createdAt: summary.createdAt
                ))
            }
            let snapshot = try PoemDeckReconciler.snapshot(records: loaded)
            records = loaded
            sourceText = snapshot.sourceText
            initialSourceText = snapshot.sourceText
            initialMismatchCount = snapshot.mismatches.count
            preview = nil
            previewedSourceText = nil
        } catch {
            errorMessage = error.localizedDescription
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
                records: records,
                title: deckName,
                deckID: deckID
            )
            previewedSourceText = sourceText
        } catch {
            preview = nil
            previewedSourceText = nil
            errorMessage = error.localizedDescription
        }
    }

    func save() async throws {
        guard canSave, let preview else { return }
        isSaving = true
        defer { isSaving = false }
        guard let order = preview.order else { return }
        _ = try await library.reconcileOrderedDeckItems(
            preview.operations, order: order, asOf: .now
        )
    }
}

public struct PoemDeckEditorView: View {
    public let deckName: String
    public let onSaved: () -> Void
    public let onCancel: () -> Void

    @State private var isPreviewing = false
    @State private var confirmsDiscard = false
    @State private var model: PoemDeckEditorModel
    @AccessibilityFocusState private var errorFocused: Bool

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
        _model = State(initialValue: PoemDeckEditorModel(
            library: library,
            deckID: deckID,
            itemTypeID: itemTypeID,
            deckName: deckName
        ))
    }

    public var body: some View {
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
                    Button("Cancel", role: .cancel) {
                        #if os(iOS)
                        if model.sourceText != model.initialSourceText { confirmsDiscard = true } else { onCancel() }
                        #else
                        onCancel()
                        #endif
                    }
                        .disabled(model.isSaving)
                        .keyboardShortcut(.cancelAction)
                }
                #if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    if isPreviewing {
                        Button("Save") { save() }.disabled(!model.canSave).accessibilityIdentifier("poemEditorSave")
                    } else {
                        Button("Preview") { model.preparePreview(); isPreviewing = model.preview != nil; errorFocused = model.errorMessage != nil }
                            .disabled(!model.canPreview).accessibilityIdentifier("poemEditorPreviewButton")
                    }
                }
                if isPreviewing { ToolbarItem(placement: .topBarLeading) { Button("Edit Text") { isPreviewing = false }.disabled(model.isSaving) } }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 620, idealHeight: 760)
        #endif
        .interactiveDismissDisabled(model.isSaving || isMobileDirty)
        .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard) { Button("Discard Changes", role: .destructive, action: onCancel); Button("Keep Editing", role: .cancel) {} }
        .task { await model.load() }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                if !isMobilePreview {
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
                        LabeledContent("Cards added", value: "\(preview.addedCount)")
                        LabeledContent("Cards retired", value: "\(preview.retiredCount)")
                        if let opening = preview.openingCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(preview.addedCount > 0 ? "Opening line · New card" : "Opening line")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(PoemCardPlanner.openingPrompt)
                                if let field = preview.updatedItemType.field(named: "Back"),
                                   case let .text(answer, _) = opening.value(for: field.id) {
                                    Text(answer)
                                }
                            }
                        } else {
                            Text("Opening-line card omitted: the title already gives the first line.")
                                .foregroundStyle(.secondary)
                        }
                        if preview.retiredOpeningCard != nil {
                            Text("Retire the opening-line card and its study progress: the title now gives the first line.")
                                .foregroundStyle(.secondary)
                        }
                        if preview.repairedMismatchCount > 0 {
                            LabeledContent(
                                "Context inconsistencies repaired",
                                value: "\(preview.repairedMismatchCount)"
                            )
                        }
                        if !preview.hasChanges {
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

            #if os(macOS)
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
                            model.errorMessage = error.localizedDescription
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
            #endif
        }
    }

    private var isMobileDirty: Bool {
        #if os(iOS)
        model.sourceText != model.initialSourceText
        #else
        false
        #endif
    }
    private var isMobilePreview: Bool {
        #if os(iOS)
        isPreviewing
        #else
        false
        #endif
    }
    private func save() {
        Task {
            do { try await model.save(); onSaved() }
            catch { model.errorMessage = error.localizedDescription; errorFocused = true }
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
                Label("Add stanza spacing", systemImage: "text.append")
            } else if change.removesStanzaBreak {
                Label("Remove stanza spacing", systemImage: "text.badge.minus")
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
