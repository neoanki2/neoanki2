import NeoAnkiApplication
import SwiftUI

public struct SyncStatusView: View {
    private let status: SyncStatus
    private let openIssues: () -> Void

    public init(status: SyncStatus, openIssues: @escaping () -> Void = {}) {
        self.status = status
        self.openIssues = openIssues
    }

    public var body: some View {
        Group {
            if case .needsAttention = status {
                Button(action: openIssues) { label }
                    .buttonStyle(.plain)
                    .neoAnkiTouchTarget()
            } else {
                label
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(foregroundStyle)
    }

    private var title: String {
        switch status {
        case .offline: "Offline"
        case .syncing: "Syncing"
        case .current: "Current"
        case .accountUnavailable: "iCloud unavailable"
        case let .needsAttention(issueCount): "\(issueCount) sync issue\(issueCount == 1 ? "" : "s")"
        }
    }

    private var symbol: String {
        switch status {
        case .offline: "icloud.slash"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .current: "checkmark.icloud"
        case .accountUnavailable: "person.crop.circle.badge.exclamationmark"
        case .needsAttention: "exclamationmark.icloud"
        }
    }

    private var foregroundStyle: Color {
        if case .needsAttention = status { return .orange }
        return .secondary
    }
}

public struct SyncIssuesView: View {
    private let issues: [SyncIssue]

    public init(issues: [SyncIssue]) {
        self.issues = issues
    }

    public var body: some View {
        AdaptiveReadingColumn {
            if issues.isEmpty {
                ContentUnavailableView(
                    "No Sync Issues",
                    systemImage: "checkmark.icloud",
                    description: Text("Preserved conflict copies will appear here without blocking local work.")
                )
            } else {
                List(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.summary).font(.headline)
                        Text(issue.createdAt, format: .dateTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Sync Issues")
    }
}
