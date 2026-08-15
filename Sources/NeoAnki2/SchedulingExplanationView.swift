import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

struct SchedulingExplanationView: View {
    @Environment(\.dismiss) private var dismiss
    let card: DueCard
    let previews: [ReviewRating: ReviewSchedulePreview]
    let health: LibrarySchedulingHealth?

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Memory") {
                    LabeledContent("Stability", value: days(memoryBefore.stability))
                    LabeledContent("Difficulty", value: memoryBefore.difficulty.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("Elapsed") {
                        Text(elapsedDescription)
                            .monospacedDigit()
                    }
                    LabeledContent("Model days", value: "\(elapsedModelDays)")
                }

                Section("Possible Answers") {
                    ForEach(ReviewRating.allCases, id: \.self) { rating in
                        if let preview = previews[rating] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(rating.studyButtonTitle)
                                        .font(.headline)
                                    Spacer()
                                    Text(preview.compactIntervalDescription)
                                        .font(.headline.monospacedDigit())
                                }
                                Text(
                                    "Stability \(days(preview.memoryBefore.stability)) → \(days(preview.memoryAfter.stability)) · "
                                        + "difficulty \(preview.memoryBefore.difficulty.formatted(.number.precision(.fractionLength(2)))) → \(preview.memoryAfter.difficulty.formatted(.number.precision(.fractionLength(2))))"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                Text("Recall \(preview.predictedRetrievability.formatted(.percent.precision(.fractionLength(1)))) · raw \(days(preview.rawIntervalDays))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Applied \(preview.operationalIntervalSeconds) seconds · due \(preview.finalDueAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let constraint = preview.constraintReason {
                                    Text("Constraint: \(constraint)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section("Policy") {
                    LabeledContent("Desired retention", value: retentionDescription)
                    LabeledContent("Memory model", value: representativePreview?.modelVersion ?? "Unavailable")
                    LabeledContent("Parameter set", value: representativePreview?.parameterSetID?.uuidString.lowercased() ?? "Unavailable")
                    LabeledContent("Elapsed-time policy", value: representativePreview?.timingPolicyVersion ?? "Unavailable")
                    LabeledContent("Interval policy", value: representativePreview?.intervalPolicyVersion ?? "Unavailable")
                    Text("Raw is the model interval. Applied is the operational interval after the displayed policy and constraint.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Scheduling Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480)
    }

    private var elapsedSeconds: TimeInterval {
        guard let lastReviewed = memoryBefore.lastReview else { return 0 }
        let reference = previews.values.first?.reviewedAt ?? .now
        return max(0, reference.timeIntervalSince(lastReviewed))
    }

    private var elapsedModelDays: Int { Int(elapsedSeconds / 86_400) }

    private var representativePreview: ReviewSchedulePreview? { previews[.good] ?? previews.values.first }
    private var memoryBefore: MemoryState { representativePreview?.memoryBefore ?? card.card.memory }
    private var retentionDescription: String {
        health?.desiredRetention.formatted(.percent.precision(.fractionLength(0...1))) ?? "Unavailable"
    }

    private var elapsedDescription: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = elapsedSeconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: elapsedSeconds) ?? "0 minutes"
    }

    private func days(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(3)))) days"
    }
}
