#if os(iOS)
import SwiftUI
import Domain
import PhotosUI
import UIKit

struct CapsuleEditor: View {
    @State var draft: CapsuleDraft
    let saveDraft: (CapsuleDraft) async throws -> Void
    let discard: (UUID) async throws -> Void
    let seal: (CapsuleDraft) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failure: String?
    @State private var savedRevision: UInt64?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoLoading = false
    @State private var showingCamera = false

    private func field<T>(_ path: WritableKeyPath<CapsuleDraft, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0; draft.revision += 1 })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if draft.companionOf == nil {
                        TextField("给胶囊起个名字", text: field(\.title)).accessibilityIdentifier("content-title")
                        Toggle("两个人各写一份", isOn: Binding(get: { draft.partnerSlotID != nil }, set: {
                            draft.partnerSlotID = $0 ? (draft.partnerSlotID ?? UUID()) : nil; draft.revision += 1
                        }))
                        DatePicker("开启时间", selection: field(\.opensAt), in: Date()...)
                    } else {
                        Text(draft.title).font(.headline)
                        LabeledContent("共同开启", value: draft.opensAt.formatted(date: .abbreviated, time: .shortened))
                    }
                } footer: { Text("封存后不能修改。双人胶囊各自保留一份内容，取消自己的封存不会移除伴侣的内容。") }
                Section("想对未来说的话（可选）") {
                    TextEditor(text: field(\.text)).frame(minHeight: 180).accessibilityIdentifier("content-body")
                }
                Section("照片（可选）") {
                    HStack(spacing: 20) {
                        Button { showingCamera = true } label: { Label("拍照", systemImage: "camera") }
                            .buttonStyle(.bordered)
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("从相册选择", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let bytes = draft.photoJPEG, let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                        Button("移除照片", role: .destructive) {
                            draft.photoJPEG = nil; draft.photoWidth = nil; draft.photoHeight = nil
                            selectedPhoto = nil; draft.revision += 1
                        }
                    }
                }
                Section {
                    Text(savedRevision == draft.revision ? "草稿已加密保存在本机，尚未发送。" : "正在保存本机草稿…").font(.footnote).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                    Button("丢弃草稿", role: .destructive) { finish { try await discard(draft.id) } }
                }
            }.scrollContentBackground(.hidden).background(SpaceStyle.paper)
                .navigationTitle(draft.companionOf == nil ? "写给未来的对方" : "写下我的一份")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("存为草稿") { finish { try await saveDraft(draft) } } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("封存") {
                            var final = draft
                            if final.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                final.title = final.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "留给未来的一张照片" : "留给未来的话"
                                final.revision += 1
                            }
                            finish { try await seal(final) }
                        }
                            .disabled(photoLoading || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.photoJPEG == nil) || draft.opensAt <= Date())
                    }
                }.disabled(saving || photoLoading)
        }.tint(SpaceStyle.accent).interactiveDismissDisabled()
            .sheet(isPresented: $showingCamera) {
                CameraPicker { bytes in
                    do {
                        let photo = try PhotoImport.prepare(bytes)
                        draft.photoJPEG = photo.jpeg; draft.photoWidth = photo.width; draft.photoHeight = photo.height
                        draft.revision += 1; failure = nil
                    } catch { failure = "无法使用这张照片，请重试。" }
                }
            }
            .task(id: draft) {
                let snapshot = draft
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    try Task.checkCancellation()
                    try await saveDraft(snapshot)
                    savedRevision = snapshot.revision
                } catch is CancellationError {} catch { failure = "草稿尚未保存，请点击“存为草稿”重试。" }
            }
            .onChange(of: selectedPhoto) { _, selection in
                guard let selection else { return }
                photoLoading = true
                Task {
                    defer { photoLoading = false }
                    do {
                        guard let bytes = try await selection.loadTransferable(type: Data.self) else {
                            throw SpaceError.invalidInput
                        }
                        let photo = try PhotoImport.prepare(bytes)
                        draft.photoJPEG = photo.jpeg
                        draft.photoWidth = photo.width
                        draft.photoHeight = photo.height
                        draft.revision += 1
                        failure = nil
                    } catch {
                        failure = error as? SpaceError == .capacity
                            ? "照片处理后仍超过 2 MB，请选择另一张。"
                            : "无法读取这张照片，请重试。"
                    }
                }
            }
    }
    private func finish(_ action: @escaping () async throws -> Void) {
        guard !saving else { return }
        saving = true
        Task {
            do { try await action(); dismiss() }
            catch { failure = error.localizedDescription; saving = false }
        }
    }
}
#endif
