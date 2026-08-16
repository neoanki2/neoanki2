import NeoAnkiSharedUI
import SwiftUI

struct StudySettingsView: View {
    @AppStorage(StudyPreferences.usesPassFailGrades) private var usesPassFailGrades = false

    var body: some View {
        Form {
            Section("Grading") {
                Toggle("Use Fail / Pass grades", isOn: $usesPassFailGrades)
                    .accessibilityIdentifier("usesPassFailGrades")

                Text("Shows two choices while studying. Fail schedules as Again; Pass schedules as Good.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 300)
    }
}
