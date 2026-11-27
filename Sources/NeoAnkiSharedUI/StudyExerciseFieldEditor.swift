import NeoAnkiCore
import SwiftUI

public struct StudyExerciseFieldEditor: View {
    @Binding private var text: String
    private let label: String
    private let defaultMode: StudyExercise.Mode

    public init(label: String, text: Binding<String>, defaultMode: StudyExercise.Mode = .target) {
        self.label = label
        self._text = text
        self.defaultMode = defaultMode
    }

    private var exercise: StudyExercise {
        (try? JSONDecoder().decode(StudyExercise.self, from: Data(text.utf8))) ?? Self.empty(defaultMode)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(label, selection: Binding(get: { exercise.mode }, set: { text = Self.empty($0).editorText })) {
                if defaultMode == .choose {
                    Text(StudyExercise.Mode.choose.title).tag(StudyExercise.Mode.choose)
                } else {
                    Text(StudyExercise.Mode.target.title).tag(StudyExercise.Mode.target)
                    Text(StudyExercise.Mode.rewrite.title).tag(StudyExercise.Mode.rewrite)
                }
            }
            switch exercise.mode {
            case .target: targetEditor
            case .rewrite:
                TextField("Source sentence", text: binding(\.prompt), axis: .vertical)
                TextField("Accepted rewrites", text: Binding(
                    get: { exercise.answers.compactMap(\.first).joined(separator: "\n") },
                    set: { value in change { $0.answers = value.components(separatedBy: .newlines).map { [$0] } } }
                ), axis: .vertical)
            case .choose: choiceEditor
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(exercise.targets.indices, id: \.self) { index in
                TextField("Text before gap \(index + 1)", text: Binding(
                    get: { exercise.parts[index] }, set: { value in change { $0.parts[index] = value } }
                ), axis: .vertical)
                TextField("Marked text (optional)", text: Binding(
                    get: { exercise.targets[index].original ?? "" },
                    set: { value in change { $0.targets[index].original = value.isEmpty ? nil : value } }
                ))
                TextField("Word bank", text: Binding(
                    get: { exercise.targets[index].choices.joined(separator: " / ") },
                    set: { value in change { $0.targets[index].choices = value.components(separatedBy: " / ").filter { !$0.isEmpty } } }
                ))
                Toggle("Allow no word", isOn: Binding(
                    get: { exercise.targets[index].allowsOmission },
                    set: { value in change { $0.targets[index].allowsOmission = value } }
                ))
                if exercise.targets.count > 1 {
                    Button("Remove gap \(index + 1)") {
                        change {
                            $0.targets.remove(at: index)
                            let following = $0.parts.remove(at: index + 1)
                            $0.parts[index] += following
                            $0.answers = $0.answers.map { row in row.enumerated().filter { $0.offset != index }.map(\.element) }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            TextField("Text after the last gap", text: Binding(
                get: { exercise.parts.last ?? "" },
                set: { value in change { $0.parts[$0.parts.count - 1] = value } }
            ), axis: .vertical)
            Button("Add Gap") {
                change {
                    $0.targets.append(.init())
                    $0.parts.append("")
                    $0.answers = $0.answers.map { $0 + [""] }
                }
            }
            .disabled(exercise.targets.count >= 16)
            TextField(exercise.targets.count == 1 ? "Accepted answers, one per line" : "Accepted answers, gaps separated by |",
                      text: Binding(
                get: { exercise.answers.map { $0.joined(separator: " | ") }.joined(separator: "\n") },
                set: { value in
                    change { $0.answers = value.components(separatedBy: .newlines).map { line in
                        line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    } }
                }
            ), axis: .vertical)
            if exercise.targets.contains(where: \.allowsOmission) {
                Text("Leave an answer position empty for no word.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var choiceEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Comparison text (optional)", text: binding(\.prompt), axis: .vertical)
            ForEach(Array(exercise.options.enumerated()), id: \.element.id) { index, option in
                HStack {
                    TextField("Option \(index + 1)", text: Binding(
                        get: { option.label }, set: { value in change { $0.options[index].label = value } }
                    ), axis: .vertical)
                    if exercise.options.count > 2 {
                        Button("Remove") {
                            change {
                                $0.options.remove(at: index)
                                if $0.correctOptionID == option.id { $0.correctOptionID = $0.options.first?.id }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Picker("Correct option", selection: binding(\.correctOptionID)) {
                ForEach(Array(exercise.options.enumerated()), id: \.element.id) { index, option in
                    Text(option.label.isEmpty ? "Option \(index + 1)" : option.label).tag(Optional(option.id))
                }
            }
            Button("Add Option") {
                change { $0.options.append(.init(id: UUID().uuidString, label: "")) }
            }
            .disabled(exercise.options.count >= 8)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<StudyExercise, Value>) -> Binding<Value> {
        Binding(get: { exercise[keyPath: keyPath] }, set: { value in change { $0[keyPath: keyPath] = value } })
    }

    private func change(_ update: (inout StudyExercise) -> Void) {
        var current = exercise
        update(&current)
        text = current.editorText
    }

    private static func empty(_ mode: StudyExercise.Mode) -> StudyExercise {
        switch mode {
        case .target:
            StudyExercise(mode: mode, parts: ["", ""], targets: [.init()], answers: [[""]])
        case .rewrite:
            StudyExercise(mode: mode, answers: [[""]])
        case .choose:
            StudyExercise(mode: mode, options: [.init(id: "1", label: ""), .init(id: "2", label: "")], correctOptionID: "1")
        }
    }
}

public extension ItemType {
    var preferredStudyExerciseMode: StudyExercise.Mode {
        guard let template = templates.first else { return .target }
        if template.interaction == .choose { return .choose }
        return template.name == StudyExercise.Mode.rewrite.title ? .rewrite : .target
    }
}
