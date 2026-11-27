import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

struct StudyExerciseControls: View {
    let exercise: StudyExercise
    let model: StudyFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch exercise.mode {
            case .target:
                ForEach(exercise.targets.indices, id: \.self) { index in
                    targetInput(index)
                }
                checkAnswer
            case .rewrite:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rewritten sentence").font(.callout.weight(.medium))
                    TextField("Rewritten sentence", text: Binding(
                        get: { model.typedAnswer }, set: { model.updateTypedAnswer($0) }
                    ), prompt: Text(""), axis: .vertical)
                    .accessibilityLabel("Rewritten sentence")
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    #endif
                    .onSubmit(model.submitTypedAnswer)
                    .accessibilityIdentifier("studyRewrite")
                }
                checkAnswer
            case .choose:
                ForEach(exercise.options) { option in
                    Button {
                        model.submitExerciseChoice(option.id)
                    } label: {
                        Text(option.label)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("studyExerciseChoice-\(option.id)")
                }
            }

            if let message = model.interactionMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("studyInteractionMessage")
            }
        }
        .disabled(model.isGrading || model.isPreparingQueue)
    }

    private func targetInput(_ index: Int) -> some View {
        let target = exercise.targets[index]
        let label: String
        if exercise.targets.count > 1 {
            label = "Gap \(index + 1)"
        } else {
            label = target.original == nil ? "Missing word or phrase" : "Replacement"
        }
        return VStack(alignment: .leading, spacing: 6) {
            if !target.choices.isEmpty {
                Text(target.choices.joined(separator: "  /  "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    targetField(index, label: label).frame(minWidth: 100, maxWidth: 220)
                    if target.allowsOmission { noWord(index) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    targetField(index, label: label)
                    if target.allowsOmission { noWord(index) }
                }
            }
        }
    }

    private func targetField(_ index: Int, label: String) -> some View {
        TextField(label, text: Binding(
            get: { model.exerciseTargets[index] ?? "" },
            set: { model.updateExerciseTarget(index, value: $0.isEmpty ? nil : $0) }
        ))
        .textFieldStyle(.roundedBorder)
        #if os(iOS)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        #endif
        .disabled(model.exerciseTargets[index] == "")
        .onSubmit(model.submitTypedAnswer)
        .accessibilityIdentifier("studyTarget\(index)")
    }

    private func noWord(_ index: Int) -> some View {
        Toggle("No word", isOn: Binding(
            get: { model.exerciseTargets[index] == "" },
            set: { model.updateExerciseTarget(index, value: $0 ? "" : nil) }
        ))
        .toggleStyle(.button)
        .accessibilityLabel(exercise.targets.count == 1 ? "No word" : "No word for gap \(index + 1)")
    }

    private var checkAnswer: some View {
        Button("Check Answer", action: model.submitTypedAnswer)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("primaryStudyAction")
    }
}
