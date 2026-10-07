import ImageIO
import NeoAnkiCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct OcclusionBitmap: @unchecked Sendable {
    let image: CGImage

    static func load(url: URL) -> Self? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else { return nil }
        return .init(image: image)
    }
}

func normalizedOcclusionRect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> OcclusionRect {
    guard size.width > 0, size.height > 0 else { return .init(x: 0, y: 0, width: 0, height: 0) }
    let x1 = min(1, max(0, start.x / size.width)), y1 = min(1, max(0, start.y / size.height))
    let x2 = min(1, max(0, end.x / size.width)), y2 = min(1, max(0, end.y / size.height))
    return .init(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
}

/// Uses the same oriented bitmap and coordinate system for editing and study.
struct OcclusionImage: View {
    let reference: MediaRef
    let store: MediaStore?
    @State private var bitmap: OcclusionBitmap?
    @State private var failed = false
    let overlay: (CGSize) -> AnyView

    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap.image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in overlay(proxy.size) }
                    }
            } else if failed {
                ContentUnavailableView("Image Unavailable", systemImage: "photo.badge.exclamationmark",
                                       description: Text("Restore the image or choose another image in Edit Item."))
            } else {
                ProgressView("Loading image…")
            }
        }
        .task(id: reference.assetHash) {
            bitmap = nil; failed = false
            do {
                guard let store else { failed = true; return }
                let url = try await store.resolve(reference)
                let loaded = await Task.detached(priority: .userInitiated) { () -> OcclusionBitmap? in
                    OcclusionBitmap.load(url: url)
                }.value
                guard !Task.isCancelled else { return }
                bitmap = loaded; failed = loaded == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

func pixelRect(_ rect: OcclusionRect, in size: CGSize) -> CGRect {
    .init(x: rect.x * size.width, y: rect.y * size.height,
          width: rect.width * size.width, height: rect.height * size.height)
}

public struct ImageOcclusionStudyView: View {
    let content: ImageOcclusionContent
    let mediaStore: MediaStore?
    let group: Int?
    let revealed: Bool

    public init(content: ImageOcclusionContent, mediaStore: MediaStore?, group: Int?, revealed: Bool) {
        self.content = content; self.mediaStore = mediaStore; self.group = group; self.revealed = revealed
    }

    public var body: some View {
        if let group, content.groups.contains(group), (try? ImageOcclusionValidation.validate(content)) != nil {
            VStack(spacing: 8) {
                OcclusionImage(reference: content.image, store: mediaStore) { size in
                    AnyView(Canvas { context, _ in
                        for rect in content.coveredRects(group: group, revealed: revealed) {
                            context.fill(Path(pixelRect(rect, in: size)), with: .color(.black))
                        }
                        for mask in content.masks where mask.group == group {
                            let rect = pixelRect(mask.rect, in: size)
                            context.stroke(Path(rect), with: .color(.yellow), lineWidth: 3)
                            if !revealed {
                                context.draw(Text("\(group)").font(.body.bold()).foregroundStyle(.white), at: .init(x: rect.midX, y: rect.midY))
                            }
                        }
                    })
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(content.image.altText ?? "Image"), group \(group)\(revealed ? ", revealed" : ", concealed")")
                .accessibilityHint("If the image is unavailable, restore it or choose another image in Edit Item.")
                let answer = content.revealedAnswerText(group: group, revealed: revealed)
                if !answer.isEmpty { Text(answer).accessibilityIdentifier("occlusion-revealed-answer") }
            }
        } else {
            ContentUnavailableView("Occlusion Unavailable", systemImage: "rectangle.dashed",
                                   description: Text("Edit the item and repair its masked regions."))
        }
    }
}

/// A small entry point in the item form. All mask work happens on a protected
/// draft; imported bytes are adopted only when that draft is accepted.
public struct ImageOcclusionFieldEditor: View {
    let label: String
    @Binding var content: ImageOcclusionContent?
    let mediaStore: MediaStore?
    @State private var draft: ImageOcclusionContent?
    @State private var editing = false
    @State private var importing = false
    @State private var confirmReplacement = false
    @State private var error: String?
    @State private var importedReference: MediaRef?
    @State private var importingBytes = false
    @State private var importTask: Task<Void, Never>?
    @State private var isActive = true
    @State private var confirmsRemoval = false
    @State private var nextGroupFloor = 1
    #if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
    #endif

    public init(label: String, content: Binding<ImageOcclusionContent?>, mediaStore: MediaStore?) {
        self.label = label; _content = content; self.mediaStore = mediaStore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            if let content {
                ImageOcclusionStudyView(content: content, mediaStore: mediaStore, group: content.groups.first, revealed: false)
                    .frame(maxHeight: 180)
                Text("\(content.groups.count) cards · \(content.masks.count) regions").font(.caption)
                Button("Edit Masks", systemImage: "rectangle.dashed") { draft = content; editing = true }
                    .accessibilityIdentifier("occlusion-edit-masks")
            }
            HStack {
                Button(content == nil ? "Choose Image…" : "Replace Image…", systemImage: "photo") {
                    if content?.masks.isEmpty == false { confirmReplacement = true }
                    else { importing = true }
                }
                .accessibilityIdentifier("occlusion-choose-image")
                #if os(iOS)
                if content == nil {
                    PhotosPicker("Photos", selection: $selectedPhoto, matching: .images)
                        .onChange(of: selectedPhoto) { _, photo in
                            guard let photo else { return }
                            importTask?.cancel()
                            importTask = Task { await ingestPhoto(photo) }
                        }
                }
                #endif
                if importingBytes { ProgressView() }
            }.disabled(mediaStore == nil || importingBytes)
            if content != nil {
                Button("Remove Image", role: .destructive) { confirmsRemoval = true }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .confirmationDialog("Replace image and clear its masks?", isPresented: $confirmReplacement, titleVisibility: .visible) {
            Button("Replace Image", role: .destructive) { importing = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The new regions will generate new cards. Canceling the mask editor keeps the original item.") }
        .confirmationDialog("Remove image and its masks?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Image", role: .destructive) {
                nextGroupFloor = max(nextGroupFloor, content?.nextGroup ?? 1)
                let ref = content?.image
                content = nil
                if let ref { Task { try? await mediaStore?.discardDraftReference(ref) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .heic, .tiff, UTType(filenameExtension: "webp") ?? .image]) { result in
            switch result {
            case let .success(url):
                importTask?.cancel()
                importTask = Task { await ingestFile(url) }
            case let .failure(failure): error = failure.localizedDescription
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $editing, onDismiss: cancelImport) { maskEditor }
        #else
        .sheet(isPresented: $editing, onDismiss: cancelImport) { maskEditor }
        #endif
        .onAppear { isActive = true }
        .onDisappear { isActive = false; importTask?.cancel() }
    }

    @ViewBuilder private var maskEditor: some View {
            if let draft {
                ImageOcclusionEditor(initial: draft, mediaStore: mediaStore) { updated in
                    let previous = content?.image
                    content = updated
                    importedReference = nil
                    editing = false
                    if let previous, previous != updated.image {
                        Task { try? await mediaStore?.discardDraftReference(previous) }
                    }
                } onCancel: { editing = false }
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 640)
                #endif
            }
    }

    private func cancelImport() {
        guard let ref = importedReference else { return }
        importedReference = nil
        Task { try? await mediaStore?.discardDraftReference(ref) }
    }

    @MainActor private func accept(_ ref: MediaRef) {
        importedReference = ref
        draft = .init(image: ref, mode: content?.mode ?? .hideAllRevealOne,
                      nextGroup: max(nextGroupFloor, content?.nextGroup ?? 1))
        editing = true
    }

    @MainActor private func ingestFile(_ url: URL) async {
        guard let mediaStore else { return }
        importingBytes = true; error = nil
        defer { importingBytes = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let ref = try await mediaStore.ingest(url: url, kind: .image)
            if Task.isCancelled || !isActive { try? await mediaStore.discardDraftReference(ref) }
            else { accept(ref) }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    #if os(iOS)
    @MainActor private func ingestPhoto(_ photo: PhotosPickerItem) async {
        guard let mediaStore else { return }
        importingBytes = true; error = nil
        defer { importingBytes = false; selectedPhoto = nil }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw MediaError.readFailed }
            let ext = photo.supportedContentTypes.compactMap(\.preferredFilenameExtension).first ?? "jpg"
            let ref = try await mediaStore.ingest(data: data, kind: .image, fileExtension: ext)
            if Task.isCancelled || !isActive { try? await mediaStore.discardDraftReference(ref) }
            else { accept(ref) }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    #endif
}

public struct ImageOcclusionEditor: View {
    @State private var draft: ImageOcclusionContent
    @State private var selected: Set<UUID> = []
    @State private var undo: [ImageOcclusionContent] = []
    @State private var redo: [ImageOcclusionContent] = []
    @State private var drawing = true
    @State private var panning = false
    @State private var zoom = 1.0
    @State private var preview = false
    @State private var revealed = false
    @State private var previewGroup = 1
    @State private var gestureStart: ImageOcclusionContent?
    @State private var pendingRect: OcclusionRect?
    @Environment(\.horizontalSizeClass) private var sizeClass
    let mediaStore: MediaStore?
    let onDone: (ImageOcclusionContent) -> Void
    let onCancel: () -> Void

    public init(initial: ImageOcclusionContent, mediaStore: MediaStore?,
                onDone: @escaping (ImageOcclusionContent) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial); self.mediaStore = mediaStore
        self.onDone = onDone; self.onCancel = onCancel
        _previewGroup = State(initialValue: initial.groups.first ?? initial.nextGroup)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls.padding()
                Divider()
                if sizeClass == .compact {
                    GeometryReader { proxy in
                        VStack(spacing: 16) {
                            canvas.frame(height: max(120, min(280, proxy.size.height * 0.45)))
                            ScrollView { inspector }
                                .accessibilityIdentifier("occlusion-region-list")
                        }.padding()
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView { inspector }.frame(width: 260)
                            .accessibilityIdentifier("occlusion-region-list")
                    }.padding()
                }
            }
            .navigationTitle("Image Occlusion")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(draft) }
                        .disabled((try? ImageOcclusionValidation.validate(draft)) == nil)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("occlusion-done")
                }
            }
            .interactiveDismissDisabled()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Tool", selection: $drawing) { Text("Draw").tag(true); Text("Select / Move").tag(false) }.pickerStyle(.segmented)
                    .disabled(preview)
                Button { undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undo.isEmpty)
                    .accessibilityLabel("Undo mask edit").keyboardShortcut("z", modifiers: .command)
                Button { redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redo.isEmpty)
                    .accessibilityLabel("Redo mask edit").keyboardShortcut("z", modifiers: [.command, .shift])
            }
            HStack {
                Toggle("Preview Cards", isOn: $preview).accessibilityIdentifier("occlusion-preview")
                Text("\(draft.groups.count) cards").font(.caption)
                Spacer()
                Button("−") { zoom = max(1, zoom - 0.5) }.accessibilityLabel("Zoom out")
                Text("\(Int(zoom * 100))%").font(.caption).monospacedDigit()
                Button("+") { zoom = min(4, zoom + 0.5) }.accessibilityLabel("Zoom in")
            }
            Toggle("Pan Image", isOn: $panning).disabled(preview)
                .accessibilityHint("Turn on to scroll the zoomed image without editing masks.")
        }.buttonStyle(.bordered)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                if preview {
                    ImageOcclusionStudyView(content: draft, mediaStore: mediaStore, group: previewGroup, revealed: revealed)
                        .frame(width: max(1, proxy.size.width) * zoom, height: max(1, proxy.size.height) * zoom)
                } else {
                    OcclusionImage(reference: draft.image, store: mediaStore) { size in
                        AnyView(editingOverlay(size: size).allowsHitTesting(!panning))
                    }
                    .frame(width: max(1, proxy.size.width) * zoom, height: max(1, proxy.size.height) * zoom)
                    .accessibilityLabel("Image canvas. Draw regions here, or use Add Region and the position controls.")
                    .accessibilityIdentifier("occlusion-canvas")
                }
            }
        }
    }

    private func editingOverlay(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).gesture(canvasGesture(size: size))
            ForEach(draft.masks) { mask in
                let rect = pixelRect(mask.rect, in: size)
                Rectangle().fill(Color.black.opacity(0.75))
                    .overlay { Text("\(mask.group)").foregroundStyle(.white).font(.body.bold()) }
                    .overlay { Rectangle().stroke(selected.contains(mask.id) ? Color.yellow : Color.white, lineWidth: selected.contains(mask.id) ? 3 : 1) }
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                if selected.contains(mask.id), !drawing {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .foregroundStyle(.black).padding(6).background(.yellow, in: Circle())
                        .frame(width: 44, height: 44).position(x: rect.maxX, y: rect.maxY)
                        .gesture(resizeGesture(mask: mask, size: size))
                        .accessibilityLabel("Resize region \(mask.group)")
                }
            }
            if let pendingRect {
                let rect = pixelRect(pendingRect, in: size)
                Rectangle().stroke(Color.yellow, style: .init(lineWidth: 2, dash: [5]))
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
            }
        }
    }

    private func canvasGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: drawing ? 2 : 0)
            .onChanged { value in
                if gestureStart == nil {
                    gestureStart = draft
                    if !drawing {
                        let point = value.startLocation
                        selected = Set(draft.masks.reversed().first(where: { pixelRect($0.rect, in: size).contains(point) }).map { [$0.id] } ?? [])
                    }
                }
                if drawing {
                    pendingRect = normalizedOcclusionRect(from: value.startLocation, to: value.location, in: size)
                } else if let original = gestureStart {
                    for index in draft.masks.indices where selected.contains(draft.masks[index].id) {
                        let rect = original.masks[index].rect
                        draft.masks[index].rect.x = min(1 - rect.width, max(0, rect.x + value.translation.width / size.width))
                        draft.masks[index].rect.y = min(1 - rect.height, max(0, rect.y + value.translation.height / size.height))
                    }
                }
            }.onEnded { _ in
                if drawing, let rect = pendingRect, rect.isValid {
                    draft.addMask(rect: rect); selected = Set(draft.masks.last.map { [$0.id] } ?? [])
                }
                finishGesture()
            }
    }

    private func resizeGesture(mask: ImageOcclusionMask, size: CGSize) -> some Gesture {
        DragGesture().onChanged { value in
            if gestureStart == nil { gestureStart = draft }
            guard let original = gestureStart?.masks.first(where: { $0.id == mask.id }),
                  let index = draft.masks.firstIndex(where: { $0.id == mask.id }) else { return }
            draft.masks[index].rect.width = min(1 - original.rect.x, max(0.001, original.rect.width + value.translation.width / size.width))
            draft.masks[index].rect.height = min(1 - original.rect.y, max(0.001, original.rect.height + value.translation.height / size.height))
        }.onEnded { _ in finishGesture() }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Image description (required)", text: Binding(get: { draft.image.altText ?? "" }, set: { text in change { $0.image.altText = text } }), axis: .vertical)
                .accessibilityIdentifier("occlusion-image-description")
            Text("Describe the diagram without revealing the masked answers.").font(.caption).foregroundStyle(.secondary)
            Picker("Masking Mode", selection: Binding(get: { draft.mode }, set: { mode in change { $0.mode = mode } })) {
                Text("Hide all, reveal one").tag(ImageOcclusionMode.hideAllRevealOne)
                Text("Hide one, reveal one").tag(ImageOcclusionMode.hideOneRevealOne)
            }.accessibilityIdentifier("occlusion-mode")
            if preview {
                Picker("Card", selection: $previewGroup) { ForEach(draft.groups, id: \.self) { Text("Group \($0)").tag($0) } }
                Toggle("Reveal Answer", isOn: $revealed).accessibilityIdentifier("occlusion-reveal")
            } else {
                Button("Add Region", systemImage: "plus") {
                    change { $0.addMask(rect: .init(x: 0.1, y: 0.1, width: 0.25, height: 0.15)) }
                    selected = Set(draft.masks.last.map { [$0.id] } ?? []); drawing = false
                }.accessibilityIdentifier("occlusion-add-region")
                ForEach(Array(draft.masks.enumerated()), id: \.element.id) { index, mask in
                    Toggle("Region \(index + 1) · Group \(mask.group)", isOn: Binding(
                        get: { selected.contains(mask.id) }, set: { isSelected in
                            if isSelected { selected.insert(mask.id) } else { selected.remove(mask.id) }
                            drawing = false
                        }))
                        .accessibilityIdentifier("occlusion-region-\(index + 1)")
                }
                if !selected.isEmpty {
                    Menu("Group Into") {
                        ForEach(draft.groups, id: \.self) { group in
                            Button("Group \(group)") { change { content in
                                for index in content.masks.indices where selected.contains(content.masks[index].id) { content.masks[index].group = group }
                            } }
                        }
                    }
                    Button("Ungroup") { change { $0.ungroup(maskIDs: selected) } }
                    Button("Delete Selected", role: .destructive) { change { $0.masks.removeAll { selected.contains($0.id) } }; selected = [] }
                        .keyboardShortcut(.delete, modifiers: [])
                }
                if selected.count == 1, let id = selected.first, let index = draft.masks.firstIndex(where: { $0.id == id }) {
                    Text("Position and size (%)").font(.headline)
                    coordinate("X", index: index, key: \.x)
                    coordinate("Y", index: index, key: \.y)
                    coordinate("Width", index: index, key: \.width)
                    coordinate("Height", index: index, key: \.height)
                    TextField("Answer text (optional)", text: Binding(get: { draft.masks[index].answerText ?? "" }, set: { text in change { $0.masks[index].answerText = text.isEmpty ? nil : text } }), axis: .vertical)
                        .accessibilityIdentifier("occlusion-answer-text")
                }
                if draft.masks.isEmpty { Text("Draw rectangles over the parts you want to recall. Each group becomes one card.").foregroundStyle(.secondary) }
            }
        }
        .onChange(of: draft.groups) { _, groups in if !groups.contains(previewGroup) { previewGroup = groups.first ?? 1 } }
    }

    private func coordinate(_ label: String, index: Int, key: WritableKeyPath<OcclusionRect, Double>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: Binding(get: { draft.masks[index].rect[keyPath: key] * 100 }, set: { value in
                guard value.isFinite else { return }
                var rect = draft.masks[index].rect
                rect[keyPath: key] = value / 100
                if rect.isValid { change { $0.masks[index].rect = rect } }
            }), format: .number.precision(.fractionLength(0...2)))
                .accessibilityLabel("Region \(label), percent")
        }
    }

    private func change(_ action: (inout ImageOcclusionContent) -> Void) {
        let previous = draft; action(&draft)
        if previous != draft { undo.append(previous); redo = [] }
    }
    private func finishGesture() {
        if let original = gestureStart, original != draft { undo.append(original); redo = [] }
        gestureStart = nil; pendingRect = nil
    }
    private func undoEdit() {
        guard let previous = undo.popLast() else { return }
        let nextGroup = draft.nextGroup
        redo.append(draft); draft = previous; draft.nextGroup = max(nextGroup, previous.nextGroup); selected = []
    }
    private func redoEdit() {
        guard let next = redo.popLast() else { return }
        let nextGroup = draft.nextGroup
        undo.append(draft); draft = next; draft.nextGroup = max(nextGroup, next.nextGroup); selected = []
    }
}
