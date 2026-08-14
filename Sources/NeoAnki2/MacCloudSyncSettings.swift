import NeoAnkiApplication
import SwiftUI

struct MacCloudSyncSettings: View {
    @Binding var isEnabled: Bool
    let status: SyncStatus
    let onChange: @MainActor (Bool) async -> Void
    let synchronize: @MainActor () async -> Void
    @State private var showsConsent = false

    var body: some View {
        Form {
            Section("Private iCloud Library") {
                Toggle("Sync this Mac", isOn: Binding(
                    get: { isEnabled },
                    set: { value in
                        if value { showsConsent = true }
                        else { isEnabled = false; Task { await onChange(false) } }
                    }
                ))
                LabeledContent("Status", value: label)
                Button("Sync Now") { Task { await synchronize() } }.disabled(!isEnabled)
            }
            Text("Each device opts in separately. Before the first upload, NeoAnki2 creates a verified SQLite backup and merges local and private CloudKit content.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 300)
        .confirmationDialog("Enable iCloud Sync?", isPresented: $showsConsent) {
            Button("Create Backup & Enable") { isEnabled = true; Task { await onChange(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your existing library is never uploaded without this confirmation. Local and iCloud libraries are merged, not replaced.")
        }
    }

    private var label: String {
        switch status {
        case .offline: "Offline"
        case .syncing: "Syncing"
        case .current: "Current"
        case .accountUnavailable: "Account unavailable"
        case let .needsAttention(count): "\(count) issues"
        }
    }
}
