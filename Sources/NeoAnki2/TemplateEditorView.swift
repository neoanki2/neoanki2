import NeoAnkiCore
import SwiftUI

struct TemplateEditorView: View {
    @Bindable var model: TemplatesModel
    var onDismiss: () -> Void = {}

    let itemType: ItemType
    let editingTemplate: Template?

    @State private var draft: TemplateDraft
    @State private var isSaving = false

    init(
        model: TemplatesModel,
        itemType: ItemType,
        editingTemplate: Template? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onDismiss = onDismiss
        self.itemType = itemType
        self.editingTemplate = editingTemplate
        _draft = State(
            initialValue: editingTemplate.map { TemplateDraft(template: $0, in: itemType) } ?? TemplateDraft()
        )
    }

    private var selectableFields: [FieldDef] {
        itemType.fields.filter(\.supportsTextInput)
    }

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("templateNameField")
            }

            Section("Fields") {
                Picker("Prompt", selection: promptBinding) {
                    Text("Choose field").tag(UUID?.none)
                    ForEach(selectableFields) { field in
                        Text(field.name).tag(Optional(field.id))
                    }
                }
                .accessibilityIdentifier("templatePromptField")

                Picker("Answer", selection: answerBinding) {
                    Text("Choose field").tag(UUID?.none)
                    ForEach(selectableFields) { field in
                        Text(field.name).tag(Optional(field.id))
                    }
                }
                .accessibilityIdentifier("templateAnswerField")
            }

            Section {
                Text("Reveal cards show the prompt first, then the answer after you choose Show Answer.")
                    .font(DesignSystem.Typography.uiHint)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                }
            }
        }
        .formStyle(.grouped)
        .neoAnkiFormTypography()
        .navigationTitle(editingTemplate == nil ? "Add Template" : "Edit Template")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onDismiss() }
                    .accessibilityIdentifier("cancelTemplateEditor")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving || !draft.isValid)
                .accessibilityIdentifier("saveTemplate")
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private var promptBinding: Binding<UUID?> {
        Binding(
            get: { draft.promptFieldID },
            set: { draft.promptFieldID = $0 }
        )
    }

    private var answerBinding: Binding<UUID?> {
        Binding(
            get: { draft.answerFieldID },
            set: { draft.answerFieldID = $0 }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if await model.saveTemplate(draft, editingID: editingTemplate?.id) {
            onDismiss()
        }
    }
}
