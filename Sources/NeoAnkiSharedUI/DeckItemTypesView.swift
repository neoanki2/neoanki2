import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

/// Explicit discovery is the only authoring surface that crosses deck boundaries.
public struct ItemTypeChooserView: View {
    @Environment(\.dismiss) private var dismiss
    let library: any LibraryBrowsing & LibraryItemTypeManaging
    let deckID: UUID?
    let onSelected: (ItemType) async -> Void
    @State private var catalog: ItemTypeCatalog?
    @State private var query = ""
    @State private var name = ""
    @State private var error: String?
    @State private var isWorking = false

    public init(library: any LibraryBrowsing & LibraryItemTypeManaging, deckID: UUID?, onSelected: @escaping (ItemType) async -> Void) {
        self.library = library; self.deckID = deckID; self.onSelected = onSelected
    }
    public var body: some View {
        NavigationStack {
            List {
                if let catalog {
                    Section("Available everywhere") {
                        ForEach(catalog.itemTypes.filter(matches)) { type in
                            Button(type.name) { choose(type) }
                        }
                    }
                    if deckID != nil {
                        Section("From another deck") {
                            ForEach(catalog.includedWithDecks) { group in
                                ForEach(group.itemTypes.filter { matches($0) && !catalog.itemTypes.contains($0) }) { type in
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
                                ForEach(catalog.needsOrganization.filter(matches)) { type in
                                    Button(type.name) { choose(type) }
                                }
                            }
                        }
                    }
                    Section(deckID == nil ? "Create shared type" : "Create for this deck") {
                        TextField("Item type name", text: $name)
                        Button("Create Item Type") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Starts with Front and Back. Edit its fields and Card setups from Item Types.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else { ProgressView("Loading item types…") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .searchable(text: $query, prompt: "Find an item type")
            .navigationTitle("Use Another Type")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isWorking) } }
            .disabled(isWorking)
            .interactiveDismissDisabled(isWorking)
            .task {
                do { catalog = try await library.loadItemTypeCatalog() }
                catch { self.error = error.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420)
        #endif
    }
    private func matches(_ type: ItemType) -> Bool { query.isEmpty || type.name.localizedCaseInsensitiveContains(query) }
    private func choose(_ type: ItemType, copy: Bool = false) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let selected: ItemType
                if copy { selected = try await library.createItemType(type.duplicated(), deckID: deckID, availableEverywhere: false) }
                else {
                    selected = type
                    if let deckID { try await library.attachItemType(id: type.id, to: deckID) }
                }
                await onSelected(selected)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func create() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let type = try await library.createItemType(BuiltInItemTypes.basic.duplicated(name: name.trimmingCharacters(in: .whitespacesAndNewlines)), deckID: deckID, availableEverywhere: deckID == nil)
                await onSelected(type); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Shared deck configuration. Definitions remain linked until explicitly copied.
public struct DeckItemTypesView: View {
    let library: any LibraryBrowsing & LibraryItemTypeManaging & LibraryDeckManaging
    let deckID: UUID
    let refreshToken: Int
    let onEdit: (ItemType) -> Void
    let onChanged: () async -> Void
    @State private var choices: AuthoringItemTypes?
    @State private var sourceDeckName = ""
    @State private var affectedDeckCounts: [UUID: Int] = [:]
    @State private var hasParent = false
    @State private var inherits = false
    @State private var catalog: ItemTypeCatalog?
    @State private var showChooser = false
    @State private var error: String?
    @State private var isWorking = false

    public init(library: any LibraryBrowsing & LibraryItemTypeManaging & LibraryDeckManaging, deckID: UUID, refreshToken: Int = 0, onEdit: @escaping (ItemType) -> Void = { _ in }, onChanged: @escaping () async -> Void = {}) {
        self.library = library; self.deckID = deckID; self.refreshToken = refreshToken; self.onEdit = onEdit; self.onChanged = onChanged
    }
    public var body: some View {
        List {
            if hasParent {
                Toggle("Use parent’s types", isOn: Binding(get: { inherits }, set: { value in
                    change { try await library.setDeckItemTypes(.init(deckID: deckID, inherits: value, itemTypeIDs: value ? [] : (choices?.itemTypes.map(\.id) ?? []), defaultItemTypeID: value ? nil : choices?.defaultItemTypeID)) }
                }))
            }
            if let choices {
                if let source = choices.sourceDeckID, source != deckID {
                    Text("Inherited from \(sourceDeckName)").font(.caption).foregroundStyle(.secondary)
                }
                Section(choices.usesSharedFallback ? "Available everywhere" : "This deck") {
                    ForEach(choices.itemTypes) { type in
                        VStack(alignment: .leading, spacing: 6) {
                            Button(type.name) { onEdit(type) }
                            let count = affectedDeckCounts[type.id] ?? 1
                            if count > 1 { Text("Available in \(count) decks").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                if choices.defaultItemTypeID == type.id { Label("Default", systemImage: "checkmark").font(.caption) }
                                else { Button("Set Default") { change { try await library.setDeckItemTypes(.init(deckID: deckID, itemTypeIDs: choices.itemTypes.map(\.id), defaultItemTypeID: type.id)) } }.font(.caption) }
                                Spacer()
                                if !choices.usesSharedFallback {
                                    Button("Remove from This Deck", role: .destructive) {
                                        change { try await library.setDeckItemTypes(.init(deckID: deckID, itemTypeIDs: attachedIDs.filter { $0 != type.id }, defaultItemTypeID: choices.defaultItemTypeID == type.id ? nil : choices.defaultItemTypeID)) }
                                    }.font(.caption)
                                }
                                Menu("More") {
                                    Button("Make Available Everywhere") { change { try await library.setItemTypeAvailability(id: type.id, availableEverywhere: true) } }
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Button("Attach or Create Item Type…", systemImage: "plus") { showChooser = true }
                Text("Removing a type changes what you can add. Existing items keep their fields and study history.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Item Types")
        .disabled(isWorking)
        .task(id: refreshToken) { await reload() }
        .sheet(isPresented: $showChooser) {
            ItemTypeChooserView(library: library, deckID: deckID) { _ in await reload(); await onChanged() }
        }
    }
    private var attachedIDs: [UUID] { choices?.usesSharedFallback == false ? (choices?.itemTypes.map(\.id) ?? []) : [] }
    private func change(_ action: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await action(); await reload(); await onChanged() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func reload() async {
        do {
            choices = try await library.authoringItemTypes(for: deckID)
            catalog = try await library.loadItemTypeCatalog()
            if let source = choices?.sourceDeckID { sourceDeckName = try await library.deck(id: source).name }
            if let safeguarding = library as? any LibraryItemTypeEditingSafeguarding {
                for type in choices?.itemTypes ?? [] {
                    affectedDeckCounts[type.id] = try await safeguarding.itemTypeEditingImpact(id: type.id).deckPaths.count
                }
            }
            hasParent = try await library.deck(id: deckID).parentID != nil
            inherits = choices?.sourceDeckID != deckID
        } catch { self.error = error.localizedDescription }
    }
}
