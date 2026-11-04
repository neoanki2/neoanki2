import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiTextEditing
import SwiftUI

struct SchedulingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SchedulingModel
    let onSaved: () async -> Void

    @State private var dismissal = DraftDismissal()
    @State private var rolloverTime: Date

    init(model: SchedulingModel, onSaved: @escaping () async -> Void) {
        self.model = model
        self.onSaved = onSaved
        _rolloverTime = State(initialValue: Self.date(for: model.rolloverMinutes))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let settingsError = model.settingsError {
                    ErrorBanner(message: settingsError)
                }

                Section {
                    DatePicker(
                        "Study day starts",
                        selection: $rolloverTime,
                        displayedComponents: .hourAndMinute
                    )
                    .disabled(model.isLoadingSettings || model.isSavingSettings)
                    .accessibilityIdentifier("studyDayRolloverPicker")

                    Button("Reset to 4:00 AM") {
                        rolloverTime = Self.date(for: StudyDay.defaultRolloverMinutes)
                    }
                    .buttonStyle(.link)
                    .disabled(model.isLoadingSettings || model.isSavingSettings)
                } header: {
                    Text("Daily Rollover")
                } footer: {
                    Text(
                        "Daily new-card limits reset at this local time. "
                            + "Changing time zones follows the Mac’s current time zone."
                    )
                }

            }
            .formStyle(.grouped)
            .navigationTitle("Study Day Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismissal.request(isDirty: pendingMinutes != model.rolloverMinutes, isBusy: model.isSavingSettings) { dismiss() }
                    }
                        .disabled(model.isSavingSettings)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSavingSettings ? "Saving…" : "Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isLoadingSettings || model.isSavingSettings)
                    .accessibilityIdentifier("saveSchedulingSettings")
                }
            }
        }
        .protectDraft(isDirty: pendingMinutes != model.rolloverMinutes, isBusy: model.isSavingSettings, dismissal: dismissal)
        .frame(minWidth: 500, idealWidth: 520, minHeight: 260)
        .onChange(of: model.rolloverMinutes) { _, minutes in
            rolloverTime = Self.date(for: minutes)
        }
    }

    private var pendingMinutes: Int {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute],
            from: rolloverTime
        )
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func save() {
        guard !model.isSavingSettings else { return }
        let minutes = pendingMinutes
        Task {
            if await model.saveRolloverMinutes(minutes) {
                await onSaved()
                dismiss()
            }
        }
    }

    private static func date(for minutes: Int) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        return calendar.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: .now
        ) ?? .now
    }
}
