import NeoAnkiCore
import SwiftUI

struct DeckSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var decksModel: DecksModel
    let deck: DeckSummary
    let onSaved: () async -> Void
    let onProgressReset: () async -> Void

    @State private var isLimited: Bool
    @State private var newCardsPerDay: Int
    @State private var isSaving = false
    @State private var isResetting = false
    @State private var showResetConfirmation = false
    @State private var resetCardCount: Int?

    init(
        decksModel: DecksModel,
        deck: DeckSummary,
        onSaved: @escaping () async -> Void = {},
        onProgressReset: @escaping () async -> Void = {}
    ) {
        self.decksModel = decksModel
        self.deck = deck
        self.onSaved = onSaved
        self.onProgressReset = onProgressReset
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
                            ? "Shared by this deck and all its subdecks. A limit of 0 pauses new cards; reviews and learning cards are never limited."
                            : "This deck does not add a limit for its subtree."
                    )
                }

                Section {
                    Button(
                        isResetting ? "Resetting Progress…" : "Reset All Progress…",
                        role: .destructive
                    ) {
                        showResetConfirmation = true
                    }
                    .disabled(isSaving || isResetting)
                    .accessibilityIdentifier("resetDeckProgress")

                    if let resetCardCount {
                        Label(
                            resetCardCount == 1
                                ? "Progress reset for 1 card."
                                : "Progress reset for \(resetCardCount) cards.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("deckProgressResetSuccess")
                    }
                } header: {
                    Text("Progress")
                } footer: {
                    Text("Returns every card in this deck and its subdecks to New. Items, deck settings, and suspended cards are kept.")
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
                    .disabled(isSaving || isResetting)
                    .accessibilityIdentifier("saveDeckSettings")
                }
            }
        }
        .confirmationDialog(
            "Reset all progress for \"\(deck.name)\"?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All Progress", role: .destructive) {
                resetProgress()
            }
            .accessibilityIdentifier("confirmResetDeckProgress")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancelResetDeckProgress")
        } message: {
            Text("This permanently removes review history for this deck and all its subdecks. This cannot be undone.")
        }
        .frame(minWidth: 420, idealWidth: 420, minHeight: 340)
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

    private func resetProgress() {
        guard !isResetting else { return }
        isResetting = true
        resetCardCount = nil
        Task {
            if let count = await decksModel.resetProgress(id: deck.id) {
                await onProgressReset()
                resetCardCount = count
            }
            isResetting = false
        }
    }
}
