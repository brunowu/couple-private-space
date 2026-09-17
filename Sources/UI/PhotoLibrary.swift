#if os(iOS)
import SwiftUI
import Photos
import PhotosUI
import UIKit
import Domain

enum PrivatePhotoLibrary {
    private static let cleanPreviousLaunch: Void = {
        let root = FileManager.default.temporaryDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("couple-preview-") {
            try? FileManager.default.removeItem(at: url)
        }
    }()

    static func temporaryJPEG(_ bytes: Data) throws -> URL {
        _ = cleanPreviousLaunch
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("couple-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("照片.jpg")
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func removeTemporary(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("couple-preview-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func save(_ bytes: Data) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else { throw SpaceError.unauthorized }
        let url = try temporaryJPEG(bytes)
        defer { removeTemporary(url) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }
}

struct ProfileAvatar: View {
    let name: String
    let photoID: UUID?
    let load: (UUID) async throws -> Data?
    let refresh: Date?
    let size: CGFloat
    @State private var image: UIImage?
    @State private var displayedPhotoID: UUID?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(SpaceStyle.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SpaceStyle.accent.opacity(0.13))
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityLabel("\(name)的头像")
        .task(id: "\(photoID?.uuidString ?? "none")-\(refresh?.timeIntervalSince1970 ?? 0)") {
            guard let photoID else {
                image = nil
                displayedPhotoID = nil
                return
            }
            if let loaded = (try? await load(photoID)).flatMap(UIImage.init(data:)) {
                image = loaded
                displayedPhotoID = photoID
            } else if displayedPhotoID != photoID {
                image = nil
                displayedPhotoID = nil
            }
        }
    }
}

struct ProfileEditor: View {
    let profile: ProfileContent?
    let loadPhoto: (UUID) async throws -> Data?
    let save: (String, (jpeg: Data, width: Int, height: Int)?, UUID?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importedPhoto: (jpeg: Data, width: Int, height: Int)?
    @State private var existingPhoto: UIImage?
    @State private var removedPhoto = false
    @State private var photoLoading = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("我的名字") {
                    TextField("想让对方怎么称呼你", text: $name)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("profile-name")
                    Text("最多 24 个字。你修改后会加密同步到对方设备。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("我的头像") {
                    if let image = importedPhoto.flatMap({ UIImage(data: $0.jpeg) }) ?? (removedPhoto ? nil : existingPhoto) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 112, height: 112).clipShape(Circle())
                    }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("选择头像照片", systemImage: "person.crop.circle.badge.plus")
                    }
                    if importedPhoto != nil || (profile?.avatarID != nil && !removedPhoto) {
                        Button("移除头像", role: .destructive) {
                            importedPhoto = nil; existingPhoto = nil; selectedPhoto = nil; removedPhoto = true
                        }
                    }
                    Text("头像只在你们的加密空间中同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden).background(SpaceStyle.paper)
            .navigationTitle("我的资料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { persist() }
                        .disabled(saving || photoLoading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(SpaceStyle.accent).interactiveDismissDisabled(saving)
        .onAppear {
            name = profile?.name ?? ""
            if let id = profile?.avatarID {
                Task { existingPhoto = (try? await loadPhoto(id)).flatMap(UIImage.init(data:)) }
            }
        }
        .onChange(of: selectedPhoto) { _, selection in
            guard let selection else { return }
            photoLoading = true
            Task {
                defer { photoLoading = false }
                do {
                    guard let bytes = try await selection.loadTransferable(type: Data.self) else { throw SpaceError.invalidInput }
                    importedPhoto = try PhotoImport.prepare(bytes)
                    removedPhoto = false; failure = nil
                } catch { failure = "无法读取这张照片，请选择另一张。" }
            }
        }
    }

    private func persist() {
        saving = true
        Task {
            do {
                try await save(name.trimmingCharacters(in: .whitespacesAndNewlines), importedPhoto,
                               removedPhoto ? nil : profile?.avatarID)
                dismiss()
            } catch { failure = "资料尚未保存，请检查名字和照片后重试。" }
            saving = false
        }
    }
}
#endif
