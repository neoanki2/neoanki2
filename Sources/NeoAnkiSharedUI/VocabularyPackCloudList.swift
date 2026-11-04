import NeoAnkiVocabularyKit
import SwiftUI

/// Native pack lists share transfer state and keep offline removal separate from cloud storage.
public struct VocabularyPackCloudList: View {
    @Bindable private var model: VocabularyPackSyncModel
    private let onLocalChange: @MainActor () async -> Void
    @State private var removing: InstalledVocabularyPack?
    @State private var replacing: CloudVocabularyPack?
    private var actionHeight: CGFloat {
        #if os(iOS)
        44
        #else
        24
        #endif
    }

    public init(model: VocabularyPackSyncModel, onLocalChange: @escaping @MainActor () async -> Void) {
        self.model = model
        self.onLocalChange = onLocalChange
    }

    public var body: some View {
        List {
            Section {
                Text(!model.isAvailable ? "iCloud is unavailable in this build. Imported packs remain available offline." : model.isEnabled
                     ? "Imported packs upload to your private iCloud library automatically. Download them on other devices when needed."
                     : "Enable iCloud sync in Settings to share packs between your devices. Downloaded packs work offline.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.isRefreshing { ProgressView("Refreshing dictionary catalog…") }
                if let error = model.catalogError {
                    Text(error).foregroundStyle(.red)
                    if model.isEnabled { Button("Retry") { Task { await model.refresh() } } }
                }
            }
            if !model.localPacks.isEmpty {
                Section("On This Device") {
                    ForEach(model.localPacks) { pack in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pack.title).font(.headline)
                            Text("\(pack.languages.joined(separator: ", ")) · \(pack.entryCount.formatted()) \(pack.entryCount == 1 ? "entry" : "entries")")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let size = model.localSizes[pack.id] {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.footnote).foregroundStyle(.secondary)
                            }
                            if model.catalog.filter({ $0.manifest.id == pack.id }).count > 1, let key = model.localKeys[pack.id] {
                                Text("Version \(key.prefix(8))").font(.caption).foregroundStyle(.secondary)
                            }
                            if let key = model.localKeys[pack.id], let transfer = model.transfers[key] {
                                progress(transfer, id: key, title: pack.title)
                            } else {
                                Label("Available offline", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
                                Button(role: .destructive) { removing = pack } label: {
                                    Text("Remove from Device").frame(minHeight: actionHeight).contentShape(Rectangle())
                                }
                                    .buttonStyle(.borderless)
                                    .disabled(model.isTransferring(packID: pack.id))
                                    .accessibilityLabel("Remove \(pack.title) from this device")
                                    .accessibilityIdentifier("removeVocabularyDownload-\(pack.id)")
                            }
                            if let error = model.errors[pack.id] { Text(error).font(.footnote).foregroundStyle(.red) }
                        }.padding(.vertical, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("vocabularyPack-\(pack.id)")
                    }
                }
            }
            let available = model.catalog.filter { !model.isDownloaded($0) }
            if !available.isEmpty {
                Section("In iCloud") {
                    ForEach(available) { pack in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pack.manifest.title).font(.headline)
                            Text("\(pack.manifest.languages.joined(separator: ", ")) · \(pack.manifest.entryCount.formatted()) \(pack.manifest.entryCount == 1 ? "entry" : "entries") · \(ByteCountFormatter.string(fromByteCount: pack.byteCount, countStyle: .file))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if model.catalog.filter({ $0.manifest.title == pack.manifest.title }).count > 1 {
                                Text("Version \(pack.id.prefix(8))").font(.caption).foregroundStyle(.secondary)
                            }
                            if let transfer = model.transfers[pack.id] {
                                progress(transfer, id: pack.id, title: pack.manifest.title)
                            } else {
                                Button {
                                    if model.localKeys[pack.manifest.id] == nil { model.download(pack) }
                                    else { replacing = pack }
                                } label: {
                                    Label(model.localKeys[pack.manifest.id] == nil ? "Download" : "Replace Download", systemImage: "icloud.and.arrow.down")
                                        .frame(minHeight: actionHeight).contentShape(Rectangle())
                                }
                                .disabled(!model.isEnabled || model.isTransferring(packID: pack.manifest.id))
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(model.localKeys[pack.manifest.id] == nil ? "Download" : "Replace download of") \(pack.manifest.title), version \(pack.id.prefix(8))")
                                .accessibilityIdentifier("downloadVocabularyPack-\(pack.manifest.id)-\(pack.id)")
                            }
                            if let error = model.errors[pack.id] { Text(error).font(.footnote).foregroundStyle(.red) }
                        }.padding(.vertical, 4).accessibilityElement(children: .contain)
                    }
                }
            }
        }
        .refreshable { await model.refresh(); await onLocalChange() }
        .task { await model.reloadLocal() }
        .onChange(of: model.localPacks) { _, _ in Task { await onLocalChange() } }
        .confirmationDialog("Remove this pack from this device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove from Device", role: .destructive) {
                if let pack = removing { Task { await model.removeDownload(packID: pack.id); await onLocalChange() } }
                removing = nil
            }
        } message: {
            Text("Saved cards are kept. Any copy already uploaded to iCloud remains available to download.")
        }
        .confirmationDialog("Replace the downloaded version?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace Download") { if let pack = replacing { model.download(pack) }; replacing = nil }
        } message: {
            Text("Download version \(replacing?.id.prefix(8) ?? "") of \(replacing?.manifest.title ?? "this pack"). The existing version stays available until the new download is complete and validated. Saved cards are kept.")
        }
    }

    private func progress(_ transfer: VocabularyPackTransferProgress, id: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(transfer.completedBytes), total: Double(max(1, transfer.totalBytes)))
            Text("\(transfer.isUploading ? "Uploading" : "Downloading") · \(ByteCountFormatter.string(fromByteCount: transfer.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file))")
                .font(.footnote).foregroundStyle(.secondary)
            if !transfer.isUploading {
                Button { model.cancelDownload(id: id) } label: {
                    Text("Cancel").frame(minHeight: actionHeight).contentShape(Rectangle())
                }.buttonStyle(.borderless).accessibilityLabel("Cancel download of \(title)")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("vocabularyPackTransfer-\(id)")
    }
}
