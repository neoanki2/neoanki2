import NeoAnkiCore
import NeoAnkiVocabularyKit
import SwiftUI

private struct VocabularyPackRootKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    public var vocabularyPackRootURL: URL? {
        get { self[VocabularyPackRootKey.self] }
        set { self[VocabularyPackRootKey.self] = newValue }
    }
}

public struct DictionaryFieldLookupSection: View {
    @Environment(\.vocabularyPackRootURL) private var rootURL
    @State private var packs: [InstalledVocabularyPack] = []
    @State private var packID: String?
    @State private var sourceID: UUID?
    @State private var destinationID: UUID?
    @State private var expanded = false
    @State private var loadingError: String?
    @State private var lookup = DictionaryLookupModel()
    @State private var autofill = DictionaryAutofillState()
    @State private var previousRequest: Request?
    private let fields: [FieldDef]
    private let text: (UUID) -> Binding<String>

    public init(fields: [FieldDef], text: @escaping (UUID) -> Binding<String>) {
        self.fields = fields.filter { $0.type == .text || $0.type == .richText }
        self.text = text
    }

    private var query: String { sourceID.map { text($0).wrappedValue } ?? "" }
    private var selectedPackURL: URL? { packs.first { $0.id == packID }?.packageURL }
    private var request: Request {
        Request(packURL: selectedPackURL, sourceID: sourceID, destinationID: destinationID, query: query, enabled: expanded)
    }

    public var body: some View {
        if fields.count >= 2 {
            Section {
                DisclosureGroup("Dictionary", isExpanded: $expanded) {
                    if let loadingError {
                        Label(loadingError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    } else if packs.isEmpty {
                        Text("Import a vocabulary pack to look up words here. You can still fill fields yourself.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Dictionary", selection: $packID) {
                            ForEach(packs) { pack in Text(pack.title).tag(Optional(pack.id)) }
                        }.accessibilityIdentifier("itemDictionaryPack")
                        Picker("Look up field", selection: $sourceID) {
                            Text("Choose a field").tag(UUID?.none)
                            ForEach(fields.filter { $0.id != destinationID }) { field in Text(field.name).tag(Optional(field.id)) }
                        }.accessibilityIdentifier("itemDictionarySource")
                        Picker("Fill field", selection: $destinationID) {
                            Text("Choose a field").tag(UUID?.none)
                            ForEach(fields.filter { $0.id != sourceID }) { field in Text(field.name).tag(Optional(field.id)) }
                        }.accessibilityIdentifier("itemDictionaryDestination")
                        Text("Type in the lookup field. A single exact match fills the destination; your edits are kept.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if lookup.isSearching {
                            ProgressView("Looking up…").accessibilityIdentifier("itemDictionaryLoading")
                        } else if let error = lookup.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        } else if lookup.hasSearched, lookup.results.isEmpty {
                            Text("No matching entries. Enter your own content or try another dictionary.")
                                .foregroundStyle(.secondary).accessibilityIdentifier("itemDictionaryNoMatch")
                        }
                        ForEach(lookup.results, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(DictionaryEntryText.render(entry)).textSelection(.enabled)
                                Button("Use Entry") { apply(DictionaryEntryText.render(entry)) }
                                    .disabled(destinationID == nil || !canAutofill)
                                    .accessibilityIdentifier("itemDictionaryEntry-\(entry.id)")
                            }.padding(.vertical, 4)
                        }
                        if destinationID != nil, !canAutofill, !lookup.results.isEmpty {
                            Text("The destination was edited. Clear it to use a dictionary entry.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .task {
                guard let rootURL else { return }
                do {
                    packs = try await InstalledVocabularyPackStore(rootURL: rootURL).installedPacks()
                    packID = packs.first?.id
                } catch { loadingError = error.localizedDescription }
            }
            .task(id: request) {
                let new = request
                lookup.invalidate()
                if let old = previousRequest,
                   old.packURL != new.packURL || old.sourceID != new.sourceID
                    || old.destinationID != new.destinationID || old.query != new.query,
                   let oldDestination = old.destinationID {
                    if let cleared = autofill.clear(replacing: text(oldDestination).wrappedValue) {
                        text(oldDestination).wrappedValue = cleared
                    }
                }
                previousRequest = new
                guard expanded, sourceID != nil, destinationID != nil else { return }
                await lookup.lookup(query: query, packURL: selectedPackURL)
            }
            .onChange(of: lookup.automaticText) { _, value in
                if let value { apply(value) }
            }
            .onDisappear { lookup.invalidate() }
        }
    }

    private var canAutofill: Bool {
        guard let destinationID else { return false }
        let current = text(destinationID).wrappedValue
        return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == autofill.lastText
    }

    private func apply(_ value: String) {
        guard let destinationID,
              let replacement = autofill.apply(value, replacing: text(destinationID).wrappedValue) else { return }
        text(destinationID).wrappedValue = replacement
    }

    private struct Request: Equatable {
        let packURL: URL?
        let sourceID: UUID?
        let destinationID: UUID?
        let query: String
        let enabled: Bool
    }
}
