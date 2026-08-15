import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

struct SchedulingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SchedulingModel
    let onSaved: () async -> Void

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
                } header: {
                    Text("Daily Rollover")
                } footer: {
                    Text(
                        "Daily new-card limits reset at this local time. "
                            + "Changing time zones follows the Mac’s current time zone."
                    )
                }

                Section("FSRS") {
                    if let health = model.health {
                        LabeledContent("Status") {
                            Label(schedulerStatus(health), systemImage: schedulerStatusIcon(health))
                        }
                        LabeledContent(
                            "Desired retention",
                            value: health.desiredRetention.formatted(.percent.precision(.fractionLength(0)))
                        )
                        LabeledContent("Maximum interval", value: "\(health.maximumIntervalDays) days")
                        LabeledContent(
                            "Automatic optimization",
                            value: health.automaticOptimizationEnabled
                                ? (health.optimizerParityVerified ? "On" : "On — activation blocked")
                                : "Off"
                        )
                        LabeledContent("Optimizer status", value: health.optimizerStatus)
                        LabeledContent("Model") {
                            Text(health.modelIdentifier)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent(
                            "Parameter set",
                            value: health.activeParameterSetID?.uuidString.lowercased() ?? "Unavailable"
                        )
                        LabeledContent("Migration", value: health.migrationStatus ?? "Unavailable")
                        LabeledContent(
                            "Legacy evidence",
                            value: health.legacyParametersQuarantined ? "Quarantined" : "None reported"
                        )
                        if let decision = health.lastOptimizationDecision {
                            LabeledContent("Last optimization", value: decision)
                            if let completedAt = health.lastOptimizationCompletedAt {
                                LabeledContent(
                                    "Completed",
                                    value: completedAt.formatted(date: .abbreviated, time: .shortened)
                                )
                            }
                            if let reason = health.lastOptimizationReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Button("Restore Defaults") {
                                Task { await model.restoreDefaults() }
                            }
                            .disabled(!health.canRestoreDefaults || model.isRecovering)

                            Button("Rollback") {
                                Task { await model.rollback() }
                            }
                            .disabled(!health.canRollback || model.isRecovering)
                        }

                        if !health.canRestoreDefaults && !health.canRollback {
                            Text("Recovery becomes available after an immutable parameter history has been created.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if model.isLoadingSettings {
                        ProgressView("Loading scheduler health…")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Scheduling Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
        .frame(minWidth: 500, idealWidth: 520, minHeight: 480)
        .onChange(of: model.rolloverMinutes) { _, minutes in
            rolloverTime = Self.date(for: minutes)
        }
    }

    private func save() {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute],
            from: rolloverTime
        )
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        Task {
            if await model.saveRolloverMinutes(minutes) {
                await onSaved()
                dismiss()
            }
        }
    }

    private func schedulerStatus(_ health: LibrarySchedulingHealth) -> String {
        guard health.optimizerParityVerified else {
            return "Personalization unavailable — verification pending"
        }
        return health.usesPopulationDefaults ? "Population defaults" : "Personalized"
    }

    private func schedulerStatusIcon(_ health: LibrarySchedulingHealth) -> String {
        guard health.optimizerParityVerified else { return "exclamationmark.shield" }
        return health.usesPopulationDefaults
            ? "checkmark.shield"
            : "person.crop.circle.badge.checkmark"
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
