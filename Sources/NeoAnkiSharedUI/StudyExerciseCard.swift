import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

/// Structured exercises use one column for the prompt, response, and feedback.
public struct StudyExerciseCard: View {
    private let card: DueCard
    private let exercise: StudyExercise
    private let model: StudyFeatureModel
    private let showsControls: Bool

    public init(card: DueCard, exercise: StudyExercise, model: StudyFeatureModel, showsControls: Bool = true) {
        self.card = card
        self.exercise = exercise
        self.model = model
        self.showsControls = showsControls
    }

    private var content: StudyAnswerReviewProjection {
        StudyAnswerReviewProjection(components: card.studyComponents)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(exercise.mode.title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("studyExerciseMode")
                ForEach(content.prompt.filter { $0.purpose == .supporting && $0.presentation.reveal == .always }) { component in
                    Text(ItemDisplay.plainText(from: component.value))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !exercise.stimulus.isEmpty {
                    Text(exercise.stimulus)
                        .font(.largeTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("studyExerciseStimulus")
                }
            }

            if model.isAnswerRevealed {
                StudyExerciseReview(
                    exercise: exercise, evaluation: model.answerEvaluation, targets: model.exerciseTargets,
                    response: model.reviewResponse, solution: content.answer.map { ItemDisplay.plainText(from: $0.value) },
                    explanation: content.explanation.map { ItemDisplay.plainText(from: $0.value) }
                )
            } else if showsControls {
                StudyExerciseControls(exercise: exercise, model: model)
            } else if exercise.mode == .choose {
                ForEach(exercise.options) { option in
                    Text(option.label)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}

public struct StudyExerciseReview: View {
    let exercise: StudyExercise
    let evaluation: AnswerEvaluation?
    let targets: [Int: String]
    let response: String?
    let solution: [String]
    let explanation: [String]

    private var referenceTargets: [String] {
        let entered = exercise.targets.indices.compactMap { targets[$0] }
        return exercise.acceptedAnswer(matching: entered) ?? exercise.answers.first ?? []
    }

    private var correctChoice: String? {
        exercise.options.first(where: { $0.id == exercise.correctOptionID })?.label
    }

    private var visibleSolution: [String] {
        guard exercise.mode == .choose, let correctChoice, let first = solution.first else { return solution }
        let remaining = first.split(separator: "\n", omittingEmptySubsequences: false)
        guard remaining.first.map(String.init) == correctChoice else { return solution }
        let example = remaining.dropFirst().joined(separator: "\n")
        return (example.isEmpty ? [] : [example]) + solution.dropFirst()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let evaluation, evaluation != .unavailable {
                Label(evaluation == .correct ? "Correct" : "Incorrect",
                      systemImage: evaluation == .correct ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.headline)
                    .foregroundStyle(evaluation == .correct ? Color.green : Color.primary)
                    .accessibilityIdentifier("studyExerciseResult")
            }
            switch exercise.mode {
            case .target:
                if evaluation == .incorrect, !targets.isEmpty {
                    answer("Your answer", value: targetList(referenceTargets.indices.map { targets[$0] }))
                }
                if !referenceTargets.isEmpty {
                    answer(evaluation == .correct ? "Answer" : "Expected", value: targetList(referenceTargets.map(Optional.some)))
                }
                solutionSection(referenceTargets.count > 1 ? "Completed text" : "Completed sentence")
            case .rewrite:
                if evaluation == .incorrect, let response { answer("Your rewrite", value: response) }
                if evaluation == .correct, let response {
                    answer("Rewritten sentence", value: response)
                } else {
                    solutionSection("Expected rewrite")
                }
            case .choose:
                if evaluation == .incorrect, let response { answer("Your choice", value: response) }
                if let correctChoice { answer("Correct choice", value: correctChoice) }
                solutionSection("Example")
            }
            if !explanation.isEmpty {
                DisclosureGroup("Explanation") {
                    Text(explanation.joined(separator: "\n\n"))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("studyExerciseExplanation")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func solutionSection(_ title: String) -> some View {
        let text = visibleSolution.joined(separator: "\n")
        return Group {
            if !text.isEmpty { answer(title, value: text) }
        }
    }

    private func answer(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func targetList(_ values: [String?]) -> String {
        values.enumerated().map { index, value in
            let text = value.map { $0.isEmpty ? "No word" : $0 } ?? "Unanswered"
            return values.count == 1 ? text : "Gap \(index + 1)  \(text)"
        }.joined(separator: "\n")
    }
}
