import Foundation
import NeoAnkiApplication
import NeoAnkiFeatures
import SwiftUI

/// Shared deck and completion entry point. The count is advisory until Start
/// rechecks the current queue.
public struct ExtraStudyAction: View {
    private let revision: UInt64
    private let regularStudyReady: Bool
    private let availability: () async throws -> Int
    private let prepare: (Int) async throws -> (@MainActor () -> Void)
    @State private var available = 0
    @State private var showsPicker = false
    @State private var availabilityChanged = false
    @State private var showsAvailabilityChange = false
    @State private var beginAfterDismissal: (@MainActor () -> Void)?

    public init(
        revision: UInt64 = 0,
        regularStudyReady: Bool = false,
        availability: @escaping () async throws -> Int,
        prepare: @escaping (Int) async throws -> (@MainActor () -> Void)
    ) {
        self.revision = revision
        self.regularStudyReady = regularStudyReady
        self.availability = availability
        self.prepare = prepare
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if available > 0 && !regularStudyReady {
                Button {
                    showsPicker = true
                } label: {
                    Text("Study Extra Cards")
#if os(iOS)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
#endif
                }
                .accessibilityIdentifier("studyExtraCards")
            }
        }
        .task(id: [revision, regularStudyReady ? 1 : 0]) {
            guard !regularStudyReady else {
                if !showsPicker { available = 0 }
                return
            }
            while !Task.isCancelled {
                let count = (try? await availability()) ?? 0
                guard !Task.isCancelled else { return }
                if !showsPicker { available = count }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(isPresented: $showsPicker, onDismiss: {
            let begin = beginAfterDismissal
            beginAfterDismissal = nil
            begin?()
            if availabilityChanged {
                availabilityChanged = false
                showsAvailabilityChange = true
            }
        }) {
            ExtraStudyBatchPicker(available: available) { count in
                do {
                    beginAfterDismissal = try await prepare(count)
                } catch is ExtraStudyStartUnavailable {
                    availabilityChanged = true
                    available = 0
                }
                showsPicker = false
            }
        }
        .alert("Study Availability Changed", isPresented: $showsAvailabilityChange) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check the deck to see what’s ready now.")
        }
    }
}

private struct ExtraStudyBatchPicker: View {
    @Environment(\.dismiss) private var dismiss
    let available: Int
    let start: (Int) async throws -> Void
    @State private var amount: String
    @State private var isStarting = false
    @State private var errorMessage: String?
    private static let inputFormat = IntegerFormatStyle<Int>.number.grouping(.never)

    init(available: Int, start: @escaping (Int) async throws -> Void) {
        self.available = available
        self.start = start
        _amount = State(initialValue: min(5, available).formatted(Self.inputFormat))
    }

    private var count: Int? {
        let digits = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }) else { return nil }
        return try? Self.inputFormat.parseStrategy.parse(digits)
    }

    private var validCount: Int? {
        guard let count, count >= 1, count <= available else { return nil }
        return count
    }

    private var step: Binding<Int> {
        Binding(
            get: { min(max(count ?? 1, 1), max(available, 1)) },
            set: { amount = $0.formatted(Self.inputFormat) }
        )
    }

    var body: some View {
#if os(iOS)
        NavigationStack {
            Form { fields }
                .navigationTitle("Study Extra Cards")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                }
                .safeAreaInset(edge: .bottom) {
                    startButton
                        .buttonStyle(.borderedProminent)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
        }
        .interactiveDismissDisabled(isStarting)
#else
        VStack(alignment: .leading, spacing: 16) {
            Text("Study Extra Cards").font(.headline)
            fields
            HStack {
                Spacer()
                cancelButton
                startButton.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 385)
#endif
    }

    @ViewBuilder
    private var fields: some View {
        Text(available == 1 ? "1 extra card available" : "\(available.formatted()) extra cards available")
            .foregroundStyle(.secondary)
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Cards to study")
                amountField
                stepper
            }
            VStack(alignment: .leading) {
                Text("Cards to study")
                HStack {
                    amountField
                    stepper
                }
            }
        }
        .disabled(isStarting)
        if isStarting {
            ProgressView("Preparing extra session…")
        } else if let errorMessage {
            Text(errorMessage).foregroundStyle(.red)
        }
    }

    private var amountField: some View {
        TextField("Number of cards", text: $amount)
#if os(iOS)
            .keyboardType(.numberPad)
#else
            .textFieldStyle(.roundedBorder)
#endif
            .frame(minWidth: 48)
            .accessibilityLabel("Cards to study")
            .accessibilityIdentifier("extraStudyCardCount")
    }

    private var stepper: some View {
        Stepper("Adjust number of cards", value: step, in: 1...max(1, available))
            .labelsHidden()
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { dismiss() }
            .disabled(isStarting)
    }

    private var startButton: some View {
        Button {
            guard let validCount, !isStarting else { return }
            isStarting = true
            errorMessage = nil
            Task {
                defer { isStarting = false }
                do {
                    try await start(validCount)
                } catch let error as UserFacingError {
                    errorMessage = error.message
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            Text("Start Extra Session")
#if os(iOS)
                .frame(maxWidth: .infinity, minHeight: 44)
#endif
        }
        .disabled(validCount == nil || isStarting)
        .accessibilityIdentifier("startExtraStudySession")
    }
}
