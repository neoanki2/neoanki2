import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

/// Explicit discovery is the only authoring surface that crosses deck boundaries.
public struct ItemTypeChooserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ItemTypeChooserFeatureModel
    let onSelected: (ItemType) async -> Void

    public init(model: ItemTypeChooserFeatureModel, onSelected: @escaping (ItemType) async -> Void) {
        _model = State(initialValue: model); self.onSelected = onSelected
    }
    public init(library: any LibraryBrowsing & LibraryItemTypeManaging, deckID: UUID?, onSelected: @escaping (ItemType) async -> Void) {
        self.init(model: ItemTypeChooserFeatureModel(authoring: .init(library: library), deckID: deckID), onSelected: onSelected)
    }
    public var body: some View {
        NavigationStack {
            List {
                if let catalog = model.catalog {
                    Section("Available everywhere") {
                        ForEach(catalog.itemTypes.filter(model.matches)) { type in
                            Button(type.name) { choose(type) }
                        }
                    }
                    if model.deckID != nil {
                        Section("From another deck") {
                            ForEach(catalog.includedWithDecks) { group in
                                ForEach(group.itemTypes.filter { model.matches($0) && !catalog.itemTypes.contains($0) }) { type in
                                    HStack {
                                        Button { choose(type) } label: {
                                            VStack(alignment: .leading) {
                                                Text(type.name)
                                                Text(group.deckPath).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Menu {
                                            Button("Make an independent copy") { choose(type, copy: true) }
                                        } label: { Image(systemName: "ellipsis") }
                                        .accessibilityLabel("More options for \(type.name)")
                                    }
                                }
                            }
                        }
                        if !catalog.needsOrganization.isEmpty {
                            Section("Needs Organization") {
                                ForEach(catalog.needsOrganization.filter(model.matches)) { type in
                                    Button(type.name) { choose(type) }
                                }
                            }
                        }
                    }
                    Section(model.deckID == nil ? "Create shared type" : "Create for this deck") {
                        TextField("Item type name", text: $model.name)
                        Button("Create Item Type") { create() }
                            .disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Starts with Front and Back. Edit its fields and Card setups from Item Types.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else { ProgressView("Loading item types…") }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .searchable(text: $model.query, prompt: "Find an item type")
            .navigationTitle("Use Another Type")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isWorking) } }
            .disabled(model.isWorking)
            .interactiveDismissDisabled(model.isWorking)
            .task { await model.load() }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420)
        #endif
    }
    private func choose(_ type: ItemType, copy: Bool = false) {
        Task {
            if await model.choose(type, independentCopy: copy, onSelected: onSelected) != nil {
                dismiss()
            }
        }
    }
    private func create() {
        Task {
            if await model.create(onSelected: onSelected) != nil { dismiss() }
        }
    }
}

/// Shared deck configuration. Definitions remain linked until explicitly copied.
public struct DeckItemTypesView: View {
    @State private var model: DeckItemTypesFeatureModel
    let refreshToken: Int
    let onEdit: (ItemType) -> Void
    @State private var showChooser = false

    public init(model: DeckItemTypesFeatureModel, refreshToken: Int = 0, onEdit: @escaping (ItemType) -> Void = { _ in }) {
        _model = State(initialValue: model); self.refreshToken = refreshToken; self.onEdit = onEdit
    }
    public init(library: any LibraryBrowsing & LibraryItemTypeManaging & LibraryDeckManaging, deckID: UUID, refreshToken: Int = 0, onEdit: @escaping (ItemType) -> Void = { _ in }, onChanged: @escaping () async -> Void = {}) {
        self.init(model: DeckItemTypesFeatureModel(authoring: .init(library: library), decks: library,
            safeguards: library as? any LibraryItemTypeEditingSafeguarding, deckID: deckID, onChanged: onChanged),
            refreshToken: refreshToken, onEdit: onEdit)
    }
    public var body: some View {
        List {
            if model.hasParent {
                Toggle("Use parent’s types", isOn: Binding(get: { model.inherits }, set: { value in
                    Task { await model.setInheritance(value) }
                }))
            }
            if let choices = model.choices {
                if let source = choices.sourceDeckID, source != model.deckID {
                    Text("Inherited from \(model.sourceDeckName)").font(.caption).foregroundStyle(.secondary)
                }
                Section(choices.usesSharedFallback ? "Available everywhere" : "This deck") {
                    ForEach(choices.itemTypes) { type in
                        VStack(alignment: .leading, spacing: 6) {
                            Button(type.name) { onEdit(type) }
                            let count = model.affectedDeckCounts[type.id] ?? 1
                            if count > 1 { Text("Available in \(count) decks").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                if choices.defaultItemTypeID == type.id { Label("Default", systemImage: "checkmark").font(.caption) }
                                else { Button("Set Default") { Task { await model.setDefault(type.id) } }.font(.caption) }
                                Spacer()
                                if !choices.usesSharedFallback {
                                    Button("Remove from This Deck", role: .destructive) {
                                        Task { await model.remove(type.id) }
                                    }.font(.caption)
                                }
                                Menu("More") {
                                    Button("Make Available Everywhere") { Task { await model.makeAvailableEverywhere(type.id) } }
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Button("Attach or Create Item Type…", systemImage: "plus") { showChooser = true }
                Text("Removing a type changes what you can add. Existing items keep their fields and study history.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { ProgressView() }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Item Types")
        .disabled(model.isWorking)
        .task(id: refreshToken) { await model.reload() }
        .sheet(isPresented: $showChooser) {
            ItemTypeChooserView(model: model.makeChooser()) { _ in await model.didChooseType() }
        }
    }
}
