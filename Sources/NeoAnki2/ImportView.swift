import NeoAnkiCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Bindable var model: ImportModel
    let itemTypes: [ItemType]
    let scope: StudyScope
    let onCancel: () -> Void
    let onImported: (Int) -> Void
    @State private var choosingMediaDirectory = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("File", value: model.selectedFileName)
                    LabeledContent("Format", value: model.format?.rawValue ?? "")

                    if model.needsItemTypeSelection {
                        Picker("Item Type", selection: $model.selectedItemTypeID) {
                            ForEach(itemTypes) { itemType in
                                Text(itemType.name).tag(Optional(itemType.id))
                            }
                        }
                        .accessibilityIdentifier("importItemTypePicker")
                    } else {
                        Text("JSON files choose the item type named in the file.")
                            .font(DesignSystem.Typography.uiSecondary)
                            .foregroundStyle(.secondary)
                    }

                    if model.requiresMediaDirectory {
                        LabeledContent(
                            "Media Folder",
                            value: model.selectedMediaDirectoryName.isEmpty
                                ? "Not selected"
                                : model.selectedMediaDirectoryName
                        )
                        Button("Choose Media Folder…") {
                            choosingMediaDirectory = true
                        }
                        .accessibilityIdentifier("chooseImportMediaDirectory")
                        Text("This file uses relative media paths. Choose the containing folder so NeoAnki2 can securely access those files during import.")
                            .font(DesignSystem.Typography.uiSecondary)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Import Items")
                        .accessibilityIdentifier("importSheet")
                }

                Section {
                    Label {
                        Text("Every row is added as a new item. Importing the same file again creates duplicates.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Duplicate Imports")
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        ErrorBanner(message: errorMessage)
                            .accessibilityIdentifier("importError")
                    }
                }
            }
            .formStyle(.grouped)
            .neoAnkiFormTypography()

            Divider()

            HStack(spacing: DesignSystem.Spacing.sm) {
                if model.isImporting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing \(model.selectedFileName)…")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("importProgress")
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    model.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isImporting)
                .accessibilityIdentifier("cancelImport")

                Button("Import") {
                    Task {
                        if await model.importSelected(scope: scope),
                           let importedCount = model.importedCount {
                            onImported(importedCount)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canImport)
                .accessibilityIdentifier("confirmImport")
            }
            .padding(DesignSystem.Spacing.md)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 360)
        .interactiveDismissDisabled(model.isImporting)
        .fileImporter(
            isPresented: $choosingMediaDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let directory = urls.first {
                _ = model.selectMediaDirectory(directory)
            }
        }
    }
}
