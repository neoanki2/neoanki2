import NeoAnkiDeckBuilderKit
import NeoAnkiTextEditing
import SwiftUI

struct DeckBuilderSheet: View {
    let registry: DeckBuilderRegistry
    let context: DeckBuilderHostContext
    let isImporting: Bool
    let onGenerated: @MainActor (GeneratedDeckBundle) -> Void
    let onCancel: @MainActor () -> Void

    @State private var selectedBuilderID: String?
    @State private var draftGuard: DraftNavigationGuard?

    init(
        registry: DeckBuilderRegistry,
        context: DeckBuilderHostContext,
        isImporting: Bool,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.registry = registry
        self.context = context
        self.isImporting = isImporting
        self.onGenerated = onGenerated
        self.onCancel = onCancel
        _selectedBuilderID = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            if let selectedBuilderID,
               let feature = registry.feature(id: selectedBuilderID) {
                feature.makeView(
                    context: context,
                    onGenerated: onGenerated,
                    onCancel: onCancel
                )
                    .onDraftNavigationGuardChange { draftGuard = $0 }
                    .disabled(isImporting)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("Builders", systemImage: "chevron.left") {
                                let leave = { self.selectedBuilderID = nil; draftGuard = nil }
                                if let draftGuard { draftGuard.request(leave) } else { leave() }
                            }
                            .disabled(isImporting || draftGuard?.isBusy == true)
                        }
                    }
            } else {
                List(registry.features) { feature in
                    Button {
                        selectedBuilderID = feature.id
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                                Text(feature.descriptor.title)
                                Text(feature.descriptor.subtitle)
                                    .font(DesignSystem.Typography.uiRowMeta)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: feature.descriptor.systemImage)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle("Deck Builders")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) {
                            onCancel()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 560, idealHeight: 760)
        .interactiveDismissDisabled(isImporting || draftGuard?.isDirty == true || draftGuard?.isBusy == true)
        .accessibilityIdentifier("deckBuilderSheet")
    }
}
