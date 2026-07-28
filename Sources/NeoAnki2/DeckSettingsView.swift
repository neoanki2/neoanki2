import NeoAnkiCore
import SwiftUI

struct DeckSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var decksModel: DecksModel
    let deck: DeckSummary
    let onSaved: () async -> Void

    @State private var isLimited: Bool
    @State private var newCardsPerDay: Int
    @State private var isSaving = false

    init(
        decksModel: DecksModel,
        deck: DeckSummary,
        onSaved: @escaping () async -> Void = {}
    ) {
        self.decksModel = decksModel
        self.deck = deck
        self.onSaved = onSaved
        _isLimited = State(initialValue: deck.newCardsPerDay != nil)
        _newCardsPerDay = State(initialValue: deck.newCardsPerDay ?? 20)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = decksModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                Section {
                    Toggle("Limit new cards per day", isOn: $isLimited)

                    if isLimited {
                        Stepper(
                            "New cards per day: \(newCardsPerDay)",
                            value: $newCardsPerDay,
                            in: 0 ... 9_999
                        )
                        .monospacedDigit()
                        .accessibilityIdentifier("deckNewCardsPerDay")
                    }
                } header: {
                    Text("New Cards")
                } footer: {
                    Text(
                        isLimited
                            ? "A limit of 0 pauses new cards. Reviews and learning cards are never limited."
                            : "This deck can introduce any number of new cards."
                    )
                }
            }
            .formStyle(.grouped)
            .navigationTitle(deck.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier("saveDeckSettings")
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 420, minHeight: 240)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let saved = await decksModel.updateNewCardsPerDay(
                id: deck.id,
                limit: isLimited ? newCardsPerDay : nil
            )
            if saved {
                await onSaved()
                dismiss()
            }
            isSaving = false
        }
    }
}
