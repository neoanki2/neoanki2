import NeoAnkiAPI
import SwiftUI

struct APISettingsView: View {
    @Bindable var model: APIControlModel
    @State private var portText = ""

    var body: some View {
        Form {
            Section("Local API") {
                Toggle("Enable local automation API", isOn: Binding(
                    get: { model.isEnabled },
                    set: { value in Task { await model.setEnabled(value) } }
                ))
                .disabled(model.isChangingState)

                LabeledContent("Address") {
                    Text("127.0.0.1:\(model.port)")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }

                HStack {
                    TextField("Port", text: $portText)
                        .frame(width: 100)
                        .accessibilityLabel("Local API port")
                    Button("Apply") {
                        guard let port = Int(portText) else { return }
                        Task { await model.applyPort(port) }
                    }
                    .disabled(Int(portText).map { !(1_024 ... 65_535).contains($0) } ?? true)
                }

                Text("The API listens only on this Mac. It is for local automation, not synchronization or remote access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let diagnostic = model.diagnostic {
                    Label(diagnostic, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("localAPIDiagnostic")
                } else {
                    Label(
                        model.isRunning ? "Listening on the configured loopback port" : "Not listening",
                        systemImage: model.isRunning ? "checkmark.circle.fill" : "stop.circle"
                    )
                    .foregroundStyle(model.isRunning ? .green : .secondary)
                }
            }

            Section("Approved clients") {
                if model.clients.isEmpty {
                    ContentUnavailableView(
                        "No Approved Clients",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("Clients appear here after you approve a pairing request.")
                    )
                } else {
                    ForEach(model.clients) { client in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(client.displayName)
                                Text(client.scopes.map(\.rawValue).sorted().joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                Task { await model.revoke(client) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 460)
        .padding()
        .navigationTitle("Local API")
        .task {
            portText = String(model.port)
            await model.reloadClients()
        }
    }
}
