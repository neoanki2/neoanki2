import NeoAnkiDeckBuilderKit
import SwiftUI

struct DeckBuilderSheet: View {
    let registry: DeckBuilderRegistry
    let isImporting: Bool
    let onGenerated: @MainActor (GeneratedDeckBundle) -> Void
    let onCancel: @MainActor () -> Void

    @State private var selectedBuilderID: String?

    init(
        registry: DeckBuilderRegistry,
        isImporting: Bool,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.registry = registry
        self.isImporting = isImporting
        self.onGenerated = onGenerated
        self.onCancel = onCancel
        _selectedBuilderID = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            if let selectedBuilderID,
               let feature = registry.feature(id: selectedBuilderID) {
                feature.makeView(onGenerated: onGenerated, onCancel: onCancel)
                    .disabled(isImporting)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("Builders", systemImage: "chevron.left") {
                                self.selectedBuilderID = nil
                            }
                            .disabled(isImporting)
                        }
                    }
            } else {
                List(registry.features) { feature in
                    Button {
                        selectedBuilderID = feature.id
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.descriptor.title)
                                Text(feature.descriptor.subtitle)
                                    .font(.caption)
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
        .frame(minWidth: 500, idealWidth: 560, minHeight: 460, idealHeight: 560)
        .interactiveDismissDisabled(isImporting)
        .accessibilityIdentifier("deckBuilderSheet")
    }
}
