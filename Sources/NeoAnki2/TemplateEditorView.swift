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

    private var selectablePromptFields: [FieldDef] {
        itemType.fields
    }

    private var selectableAnswerFields: [FieldDef] {
        itemType.fields.filter { $0.isTextLike || $0.type == .number }
    }

    private var promptField: FieldDef? {
        guard let id = draft.promptFieldID else { return nil }
        return itemType.field(id)
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
                    ForEach(selectablePromptFields) { field in
                        Text(field.name).tag(Optional(field.id))
                    }
                }
                .accessibilityIdentifier("templatePromptField")

                Picker("Answer", selection: answerBinding) {
                    Text("Choose field").tag(UUID?.none)
                    ForEach(selectableAnswerFields) { field in
                        Text(field.name).tag(Optional(field.id))
                    }
                }
                .accessibilityIdentifier("templateAnswerField")

                if promptField?.supportsMediaInput == true {
                    Picker("Media behavior", selection: $draft.promptMediaBehavior) {
                        Text("Default").tag(MediaBehavior.default)
                        Text("Autoplay").tag(MediaBehavior.autoplay)
                        Text("Play on tap").tag(MediaBehavior.playOnTap)
                        Text("Loop").tag(MediaBehavior.loop)
                    }
                    .accessibilityIdentifier("templateMediaBehavior")
                }
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
            if editingTemplate != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteTemplate() }
                    }
                    .accessibilityIdentifier("deleteTemplate")
                }
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

    private func deleteTemplate() async {
        guard let editingTemplate else { return }
        if await model.deleteTemplate(id: editingTemplate.id) {
            onDismiss()
        }
    }
}
