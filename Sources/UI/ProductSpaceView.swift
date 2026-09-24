#if os(iOS)
import SwiftUI
import UIKit
import Domain
import PhotosUI
import QuickLook
import UserNotifications
import ImageIO
import UniformTypeIdentifiers
import AVKit

enum SpaceStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.88, green: 0.62, blue: 0.54, alpha: 1)
            : UIColor(red: 0.70, green: 0.37, blue: 0.31, alpha: 1)
    })
    static let sage = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.65, green: 0.75, blue: 0.67, alpha: 1)
            : UIColor(red: 0.36, green: 0.48, blue: 0.40, alpha: 1)
    })
    static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
            : UIColor(red: 0.985, green: 0.977, blue: 0.963, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
            : .white
    })
    static let softSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
            : UIColor(red: 0.977, green: 0.969, blue: 0.955, alpha: 1)
    })
    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor(red: 0.78, green: 0.72, blue: 0.67, alpha: 0.16)
    })
}

private struct SpacePanel: ViewModifier {
    var radius: CGFloat = 26
    func body(content: Content) -> some View {
        content
            .background(SpaceStyle.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(SpaceStyle.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 18, x: 0, y: 7)
    }
}

private extension View {
    func spacePanel(radius: CGFloat = 26) -> some View { modifier(SpacePanel(radius: radius)) }
}

private struct SpaceIntro: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(SpaceStyle.accent)
                .frame(width: 52, height: 52)
                .background(SpaceStyle.accent.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spacePanel()
    }
}

private struct ChatEntry: Identifiable {
    enum Content { case text(Message), photo(MediaAsset) }
    let id: UUID
    let author: UUID
    let version: Version
    let content: Content
}

/// The shipping interface consumes shared state and reports persistence errors before clearing drafts.
public struct ProductSpaceView: View {
    let state: SharedState
    let localID: UUID
    let peerDeviceID: UUID?
    let pairingCode: String?
    let showPairingFinal: (() -> Void)?
    let isCycleOwner: Bool
    let deliveries: [UUID: DeliveryState]
    let save: (EventPayload, UUID) async throws -> Void
    let savePhoto: (Data, Int, Int) async throws -> Void
    let saveSticker: (Data, String, Int, Int) async throws -> Void
    let saveVideo: (Data, String, Int, Int) async throws -> Void
    let saveAudio: (Data) async throws -> Void
    let saveMemoryWithPhoto: (MemoryContent, Data, Int, Int, UUID) async throws -> Void
    let saveMemoryWithVideo: (MemoryContent, Data, String, Int, Int, UUID) async throws -> Void
    let loadPhoto: (UUID) async throws -> Data?
    let updateProfile: (String, (jpeg: Data, width: Int, height: Int)?, UUID?) async throws -> Void
    let privateCycle: CycleEntry?
    let cycle: (CycleEntry) async throws -> Void
    let configureReminders: (Bool, Int, QuietHours) async throws -> Void
    let reminderStatus: String
    let syncStatus: String
    let photoRefresh: Date?
    let interruptedMediaIDs: Set<UUID>
    let mediaProgress: (UUID) async -> Double?
    let retryMedia: (UUID) async -> Void
    let retry: () async -> Void
    let affection: Affection?
    let sendAffection: (AffectionKind) async throws -> Bool
    let capsuleDrafts: [CapsuleDraft]
    let openedCapsules: Set<UUID>
    let saveCapsuleDraft: (CapsuleDraft) async throws -> Void
    let sealCapsuleDraft: (CapsuleDraft) async throws -> Void
    let discardCapsuleDraft: (UUID) async throws -> Void
    let openCapsule: (UUID) async throws -> Void
    let capsuleReminderStatus: String
    let configureCapsuleReminders: (Bool) async throws -> Void
    let anniversaryReminderStatus: String
    let configureAnniversaryReminders: (Bool, Int) async throws -> Void
    let notificationDestination: NotificationDestination?
    let consumeNotification: () -> Void
    let openWishReminder: (UUID) async throws -> Void
    let prepareCapsuleDraft: (CapsuleDraft) async throws -> CapsuleDraft
    let pushStatus: String
    let configurePush: (Bool, Bool, Bool) async throws -> Void
    let revokePairing: () async throws -> Void
    let appLockEnabled: Bool
    let configureAppLock: (Bool) async throws -> Void
    let backupStatus: String
    let createEncryptedBackup: () async throws -> SpaceBackupArtifact
    let verifyEncryptedBackup: (URL, String) async throws -> SpaceBackupPreview
    @State private var showRevokeConfirmation = false
    @State private var revoking = false
    @State private var backupBusy = false
    @State private var backupRecoveryKey = ""
    @State private var backupPreview: SpaceBackupPreview?
    @State private var showingBackupImporter = false
    @State private var backupVerificationURL: URL?
    @State private var backupVerificationKey = ""
    @State private var showingBackupVerifier = false
    @State private var pushEnabled = UserDefaults.standard.object(forKey: "affection-push-enabled") as? Bool ?? true
    @State private var messagePushEnabled = UserDefaults.standard.object(forKey: "message-push-enabled") as? Bool ?? true
    @State private var wishPushEnabled = UserDefaults.standard.object(forKey: "wish-push-enabled") as? Bool ?? true
    @State private var capsuleRemindersEnabled = UserDefaults.standard.bool(forKey: "capsule-reminders-enabled")
    @State private var anniversaryRemindersEnabled = UserDefaults.standard.bool(forKey: "anniversary-reminders-enabled")
    @State private var anniversaryReminderDays = UserDefaults.standard.object(forKey: "anniversary-reminder-days") as? Int ?? 3
    @State private var selectedWish: UUID?
    @State private var editingCapsule: CapsuleDraft?
    @AppStorage("affection-haptics") private var affectionHaptics = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var affectionStatus: String?
    @State private var tab = 0
    @State private var draft = ""
    @State private var selectedChatPhotos: [PhotosPickerItem] = []
    @State private var selectedChatVideo: PhotosPickerItem?
    @State private var showingChatCamera = false
    @State private var showingAudioRecorder = false
    @State private var showingStickerLibrary = false
    @StateObject private var stickerLibrary = StickerLibrary()
    @State private var stickerSmokeStarted = false
    @State private var photoSending = false
    @State private var quotedMessage: Message?
    @State private var selectingChat = false
    @State private var selectedChatEntries: Set<UUID> = []
    @State private var sharePayload: ChatSharePayload?
    @State private var photoPreview: PhotoPreview?
    @State private var chatVisibleLimit = 80
    @State private var loadingEarlierChat = false
    @AppStorage("chat-last-read-clock") private var chatLastReadClock = 0
    @AppStorage("chat-read-clock-initialized") private var chatReadClockInitialized = false
    @State private var composing: Composer?
    @State private var selectedCapsule: UUID?
    @State private var selectedMemory: UUID?
    @State private var editingProfile = false
    @State private var editingAnniversary: AnniversaryDraft?
    @State private var wishFilter: WishStatus = .active
    @State private var wishSection = 0
    @State private var memorySection = 0
    @State private var category: ListCategory = .eat
    @State private var sending = false
    @State private var failure: String?
    @State private var remindersEnabled = UserDefaults.standard.bool(forKey: "wish-reminders-enabled")
    @State private var reminderDays = min(30, max(1, UserDefaults.standard.object(forKey: "wish-reminder-days") as? Int ?? 7))
    @State private var quietEnabled = UserDefaults.standard.bool(forKey: "wish-quiet-enabled")
    @State private var quietStart = UserDefaults.standard.object(forKey: "wish-quiet-start") as? Int ?? 22
    @State private var quietEnd = UserDefaults.standard.object(forKey: "wish-quiet-end") as? Int ?? 8
    @FocusState private var chatFocused: Bool
    private var paper: Color { SpaceStyle.paper }
    private var card: Color { SpaceStyle.surface }
    private func name(for author: UUID) -> String {
        state.profiles[author]?.value.name ?? (author == localID ? "我" : "伴侣")
    }
    private func avatarID(for author: UUID) -> UUID? { state.profiles[author]?.value.avatarID }
    private var peerName: String { peerDeviceID.map(name(for:)) ?? "伴侣" }
    private var peerAvatarID: UUID? { peerDeviceID.flatMap(avatarID(for:)) }

    public init(state: SharedState, localID: UUID, peerDeviceID: UUID? = nil, pairingCode: String? = nil,
                showPairingFinal: (() -> Void)? = nil, isCycleOwner: Bool,
                deliveries: [UUID: DeliveryState], reminderStatus: String, syncStatus: String,
                photoRefresh: Date?,
                interruptedMediaIDs: Set<UUID> = [],
                mediaProgress: @escaping (UUID) async -> Double? = { _ in nil },
                save: @escaping (EventPayload, UUID) async throws -> Void,
                privateCycle: CycleEntry?, cycle: @escaping (CycleEntry) async throws -> Void,
                savePhoto: @escaping (Data, Int, Int) async throws -> Void,
                saveSticker: @escaping (Data, String, Int, Int) async throws -> Void,
                saveVideo: @escaping (Data, String, Int, Int) async throws -> Void = { _, _, _, _ in },
                saveAudio: @escaping (Data) async throws -> Void = { _ in },
                saveMemoryWithPhoto: @escaping (MemoryContent, Data, Int, Int, UUID) async throws -> Void,
                saveMemoryWithVideo: @escaping (MemoryContent, Data, String, Int, Int, UUID) async throws -> Void = { _, _, _, _, _, _ in },
                loadPhoto: @escaping (UUID) async throws -> Data?,
                retryMedia: @escaping (UUID) async -> Void = { _ in },
                updateProfile: @escaping (String, (jpeg: Data, width: Int, height: Int)?, UUID?) async throws -> Void,
                configureReminders: @escaping (Bool, Int, QuietHours) async throws -> Void,
                retry: @escaping () async -> Void, affection: Affection?,
                sendAffection: @escaping (AffectionKind) async throws -> Bool,
                capsuleDrafts: [CapsuleDraft], openedCapsules: Set<UUID>,
                saveCapsuleDraft: @escaping (CapsuleDraft) async throws -> Void,
                sealCapsuleDraft: @escaping (CapsuleDraft) async throws -> Void,
                discardCapsuleDraft: @escaping (UUID) async throws -> Void,
                openCapsule: @escaping (UUID) async throws -> Void,
                capsuleReminderStatus: String, configureCapsuleReminders: @escaping (Bool) async throws -> Void,
                anniversaryReminderStatus: String, configureAnniversaryReminders: @escaping (Bool, Int) async throws -> Void,
                notificationDestination: NotificationDestination?, consumeNotification: @escaping () -> Void,
                openWishReminder: @escaping (UUID) async throws -> Void,
                prepareCapsuleDraft: @escaping (CapsuleDraft) async throws -> CapsuleDraft,
                pushStatus: String, configurePush: @escaping (Bool, Bool, Bool) async throws -> Void,
                revokePairing: @escaping () async throws -> Void,
                appLockEnabled: Bool, configureAppLock: @escaping (Bool) async throws -> Void,
                backupStatus: String,
                createEncryptedBackup: @escaping () async throws -> SpaceBackupArtifact,
                verifyEncryptedBackup: @escaping (URL, String) async throws -> SpaceBackupPreview) {
        self.state = state; self.localID = localID; self.peerDeviceID = peerDeviceID
        self.pairingCode = pairingCode; self.showPairingFinal = showPairingFinal; self.isCycleOwner = isCycleOwner
        self.deliveries = deliveries; self.save = save; self.cycle = cycle
        self.savePhoto = savePhoto; self.saveSticker = saveSticker; self.saveVideo = saveVideo; self.saveAudio = saveAudio
        self.saveMemoryWithPhoto = saveMemoryWithPhoto; self.saveMemoryWithVideo = saveMemoryWithVideo; self.loadPhoto = loadPhoto
        self.updateProfile = updateProfile
        self.privateCycle = privateCycle
        self.configureReminders = configureReminders; self.reminderStatus = reminderStatus
        self.syncStatus = syncStatus; self.photoRefresh = photoRefresh; self.retry = retry
        self.interruptedMediaIDs = interruptedMediaIDs; self.retryMedia = retryMedia
        self.mediaProgress = mediaProgress
        self.affection = affection; self.sendAffection = sendAffection
        self.capsuleDrafts = capsuleDrafts; self.openedCapsules = openedCapsules
        self.saveCapsuleDraft = saveCapsuleDraft; self.sealCapsuleDraft = sealCapsuleDraft
        self.discardCapsuleDraft = discardCapsuleDraft; self.openCapsule = openCapsule
        self.capsuleReminderStatus = capsuleReminderStatus; self.configureCapsuleReminders = configureCapsuleReminders
        self.anniversaryReminderStatus = anniversaryReminderStatus; self.configureAnniversaryReminders = configureAnniversaryReminders
        self.notificationDestination = notificationDestination; self.consumeNotification = consumeNotification
        self.openWishReminder = openWishReminder
        self.prepareCapsuleDraft = prepareCapsuleDraft
        self.pushStatus = pushStatus; self.configurePush = configurePush
        self.revokePairing = revokePairing
        self.appLockEnabled = appLockEnabled; self.configureAppLock = configureAppLock
        self.backupStatus = backupStatus
        self.createEncryptedBackup = createEncryptedBackup
        self.verifyEncryptedBackup = verifyEncryptedBackup
    }

    public var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                chat.navigationTitle("我们").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(selectingChat ? "取消" : "选择") {
                                selectingChat.toggle()
                                if !selectingChat { selectedChatEntries.removeAll() }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if selectingChat {
                                Button {
                                    shareSelectedChat()
                                } label: { Image(systemName: "square.and.arrow.up") }
                                    .disabled(selectedChatEntries.isEmpty)
                                    .accessibilityLabel("分享所选对话")
                            } else {
                                Button {
                                    exportAllChat()
                                } label: { Image(systemName: "square.and.arrow.up") }
                                    .accessibilityLabel("导出全部对话记录")
                            }
                        }
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("完成") { chatFocused = false }
                                .accessibilityIdentifier("dismiss-chat-keyboard")
                        }
                    }
            }
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .badge(unreadCount).tag(0)
            NavigationStack { wishes.navigationTitle("小小愿望").toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = wishSection == 0 ? .wish : .checklist(nil, category) } label: { Image(systemName: "plus") }
                        .accessibilityLabel(wishSection == 0 ? "创建愿望" : "添加清单")
                }
            } }.tabItem { Label("愿望", systemImage: "star") }.tag(1)
            NavigationStack { memories.navigationTitle("我们的回忆").toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if memorySection == 0 { composing = .memory(nil) }
                        else { editingCapsule = CapsuleDraft() }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel(memorySection == 0 ? "添加回忆" : "创建时间胶囊")
                }
            } }.tabItem { Label("回忆", systemImage: "photo.on.rectangle") }.tag(2)
            NavigationStack { together.navigationTitle("我们").navigationBarTitleDisplayMode(.inline) }
                .tabItem { Label("我们", systemImage: "person.2") }.tag(3)
        }.tint(SpaceStyle.accent)
        .onChange(of: tab) { _, selected in
            chatFocused = false
            if selected == 0 {
                markChatRead()
                Task { await clearRemoteNotifications(for: .message) }
            }
            if selected == 1 { Task { await clearRemoteNotifications(for: .wish) } }
        }
        .toolbarBackground(SpaceStyle.paper, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .overlay(alignment: .top) {
            if let affection {
                HStack(spacing: 12) {
                    Image(systemName: affection.kind.symbol).font(.title2).foregroundStyle(SpaceStyle.accent)
                    ProfileAvatar(name: peerName, photoID: peerAvatarID,
                                  load: loadPhoto, refresh: photoRefresh, size: 34)
                    Text(affectionText(affection.kind))
                        .font(.subheadline).accessibilityIdentifier("affection-received")
                    Spacer(minLength: 0)
                    Button("回应") { sendFeeling(affection.kind) }.font(.subheadline).tint(SpaceStyle.accent)
                }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: affection?.id)
        .sensoryFeedback(.impact(weight: .light), trigger: affection?.id) { _, next in affectionHaptics && next != nil }
        .sheet(item: $composing) { item in
            ContentComposer(item: item, save: save, saveMemoryWithPhoto: saveMemoryWithPhoto,
                            saveMemoryWithVideo: saveMemoryWithVideo)
        }
        .sheet(item: $editingCapsule) { value in
            CapsuleEditor(draft: value, saveDraft: saveCapsuleDraft, discard: discardCapsuleDraft,
                          seal: sealCapsuleDraft)
        }
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(items: payload.items)
        }
        .sheet(isPresented: $showingBackupVerifier) {
            NavigationStack {
                Form {
                    Section("恢复密钥") {
                        SecureField("CPS1-…", text: $backupVerificationKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section {
                        Text("这里只校验文件完整性、恢复密钥和设备身份，不会导入或修改当前空间。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("校验加密备份")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showingBackupVerifier = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("校验") { verifySelectedBackup() }.disabled(backupVerificationKey.isEmpty || backupBusy)
                    }
                }
            }
        }
        .fullScreenCover(item: $photoPreview) { preview in
            PhotoViewer(preview: preview, load: loadPhoto)
        }
        .sheet(isPresented: $showingChatCamera) {
            CameraPicker { data in Task { await sendCapturedPhoto(data) } }
        }
        .sheet(isPresented: $showingAudioRecorder) {
            AudioRecorderSheet { data in try await saveAudio(data) }
        }
        .sheet(isPresented: $showingStickerLibrary) {
            StickerLibraryView(library: stickerLibrary) { sticker in
                Task { await sendSticker(sticker) }
            }
        }
        .sheet(isPresented: $editingProfile) {
            ProfileEditor(profile: state.profiles[localID]?.value, loadPhoto: loadPhoto, save: updateProfile)
        }
        .task(id: notificationDestination?.id) {
            guard let destination = notificationDestination else { return }
            // Keep a pending destination while a private editor is open; never discard unsaved input.
            if editingCapsule != nil || composing != nil { return }
            await route(destination)
        }
        .onChange(of: editingCapsule == nil && composing == nil) { _, closed in
            if closed, let destination = notificationDestination { Task { await route(destination) } }
        }
        .sheet(isPresented: Binding(get: { selectedWish != nil }, set: { if !$0 { selectedWish = nil } })) {
            selectedWishSheet
        }
        .sheet(isPresented: Binding(get: { selectedMemory != nil }, set: { if !$0 { selectedMemory = nil } })) {
            selectedMemorySheet
        }
        .sheet(isPresented: Binding(get: { selectedCapsule != nil }, set: { if !$0 { selectedCapsule = nil } })) {
            selectedCapsuleSheet
        }
        .alert("未能完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("知道了") { failure = nil }
        } message: { Text(failure ?? "") }
        .confirmationDialog("解除这段配对？", isPresented: $showRevokeConfirmation, titleVisibility: .visible) {
            Button("解除配对", role: .destructive) {
                Task {
                    revoking = true; defer { revoking = false }
                    do { try await revokePairing() }
                    catch { failure = "暂时未能解除配对。请检查网络后重试；此前保存的内容没有被删除。" }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("解除后双方都不能再用这段配对同步。两台设备上已经保存的内容不会自动删除，也无法远程抹去伴侣的副本。")
        }
        .onChange(of: selectedChatPhotos) { _, photos in
            if !photos.isEmpty { Task { await sendSelectedPhotos(photos) } }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                backupVerificationURL = url
                backupVerificationKey = ""
                showingBackupVerifier = true
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .onChange(of: chatLatestClock) { _, _ in if tab == 0 { markChatRead() } }
        .onAppear {
            if !chatReadClockInitialized {
                chatLastReadClock = chatLatestClock; chatReadClockInitialized = true
            } else if tab == 0 { markChatRead() }
            #if DEBUG && targetEnvironment(simulator)
            if !stickerSmokeStarted,
               let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--sticker-import-smoke"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                stickerSmokeStarted = true
                stickerLibrary.importPack(URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1]))
            }
            #endif
        }
        .tint(SpaceStyle.accent)
    }

    @ViewBuilder private var selectedWishSheet: some View {
        NavigationStack {
            if let id = selectedWish, let wish = state.wishes[id] {
                VStack(alignment: .leading, spacing: 20) {
                    Text(wish.text).font(.title2)
                    Text(statusTitle(wish.status)).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("一个小小愿望")
                .toolbar { Button("完成") { selectedWish = nil } }
            }
        }
    }

    @ViewBuilder private var selectedMemorySheet: some View {
        NavigationStack {
            if let id = selectedMemory, let record = state.journal.memories[id], !record.value.deleted {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(record.value.title).font(.largeTitle.bold())
                        Text(record.value.date, style: .date).foregroundStyle(.secondary)
                        if !record.value.text.isEmpty { Text(record.value.text).textSelection(.enabled) }
                        if let mediaID = record.value.mediaID {
                            attachmentView(mediaID)
                        }
                        if record.value.sourceID != nil { Label("留自两个人的日常", systemImage: "link").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.toolbar { Button("完成") { selectedMemory = nil } }
            } else { ContentUnavailableView("这段回忆已移除", systemImage: "book.closed") }
        }
    }

    @ViewBuilder private var selectedCapsuleSheet: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let id = selectedCapsule, let record = state.journal.capsules[id] {
                    let parts = state.journal.contributions(to: id)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Label("写给这一刻", systemImage: "envelope.open").foregroundStyle(SpaceStyle.accent)
                            Text(record.value.title).font(.largeTitle.bold())
                            ForEach(parts) { part in
                                capsuleContribution(part, now: context.date)
                            }
                            if record.value.partnerSlotID != nil && parts.count == 1 {
                                Text("另一份没有封存。已经到期的内容仍然可以阅读。").font(.footnote).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    }
                } else { ContentUnavailableView("还未到开启时间", systemImage: "lock", description: Text("胶囊已取消或尚未到期。")) }
            }.toolbar { Button("完成") { selectedCapsule = nil } }
        }
    }

    @ViewBuilder private func capsuleContribution(_ part: JournalRecord<CapsuleContent>, now: Date) -> some View {
        if state.journal.canOpen(part, now: now), openedCapsules.contains(part.id) {
            Text("\(name(for: part.author))写下的").font(.caption).foregroundStyle(.secondary)
            if !part.value.text.isEmpty { Text(part.value.text).textSelection(.enabled).accessibilityIdentifier("capsule-content") }
            if let mediaID = part.value.mediaID {
                attachmentView(mediaID)
            }
            Button("留作共同回忆") { rememberCapsule(part) }.buttonStyle(.bordered)
        } else {
            Label(state.journal.isCancelled(part) ? "这一份已取消封存" : "这一份尚未打开", systemImage: "lock").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func attachmentView(_ mediaID: UUID) -> some View {
        let asset = state.media[mediaID]
        if let manifest = asset?.manifest, manifest.kind.hasPrefix("video/") {
            VideoBubble(id: mediaID, kind: manifest.kind, width: manifest.width, height: manifest.height,
                        load: loadPhoto, refresh: photoRefresh,
                        interrupted: interruptedMediaIDs.contains(mediaID),
                        progress: { await mediaProgress(mediaID) }, retry: { await retryMedia(mediaID) })
        } else {
            PhotoBubble(id: mediaID, kind: manifestKind(asset), load: loadPhoto, refresh: photoRefresh,
                        interrupted: interruptedMediaIDs.contains(mediaID),
                        progress: { await mediaProgress(mediaID) }, retry: { await retryMedia(mediaID) },
                        preview: { photoPreview = PhotoPreview(photoIDs: [mediaID], selectedID: mediaID, seedImage: $0) })
        }
    }
    private func manifestKind(_ asset: MediaAsset?) -> String { asset?.manifest.kind ?? "image/jpeg" }

    private var chatEntries: [ChatEntry] {
        let messages = state.messages.values.map { ChatEntry(id: $0.id, author: $0.author, version: $0.version, content: .text($0)) }
        let photos = state.media.values.filter { $0.destination == .chat }
            .map { ChatEntry(id: $0.id, author: $0.author, version: $0.version, content: .photo($0)) }
        return (messages + photos).sorted { $0.version < $1.version }
    }
    private var visibleChatEntries: [ChatEntry] {
        Array(chatEntries.suffix(chatVisibleLimit))
    }
    private var chatPhotoIDs: [UUID] {
        chatEntries.compactMap { entry in
            if case .photo(let asset) = entry.content, asset.manifest.kind.hasPrefix("image/") { return asset.id }
            return nil
        }
    }

    private var chatLatestClock: Int {
        Int(min(UInt64(Int.max), chatEntries.map(\.version.clock).max() ?? 0))
    }
    private var unreadCount: Int {
        guard chatReadClockInitialized else { return 0 }
        return chatEntries.filter { $0.author != localID && $0.version.clock > UInt64(max(0, chatLastReadClock)) }.count
    }
    private func markChatRead() { chatLastReadClock = chatLatestClock }
    private func entryCreatedAt(_ entry: ChatEntry) -> Date? {
        switch entry.content { case .text(let value): value.createdAt; case .photo(let value): value.createdAt }
    }
    private func showsDateDivider(at index: Int, in entries: [ChatEntry]) -> Bool {
        guard entries.indices.contains(index), let date = entryCreatedAt(entries[index]) else { return false }
        guard index > 0, let previous = entryCreatedAt(entries[index - 1]) else { return true }
        return !Calendar.current.isDate(date, inSameDayAs: previous)
    }
    private func dateDividerTitle(for entry: ChatEntry) -> String {
        guard let date = entryCreatedAt(entry) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.year().month(.wide).day())
    }
    private func chatExportText(for entries: [ChatEntry]) -> String {
        let heading = "我们的对话\n导出时间：\(Date().formatted(date: .long, time: .shortened))\n\n"
        return heading + entries.map { entry in
            let time = entryCreatedAt(entry)?.formatted(date: .numeric, time: .shortened) ?? "时间未记录"
            let content: String
            switch entry.content {
            case .text(let value):
                let body = StickerReference.stickerID(from: value.text) == nil ? value.text : "[表情]"
                if let replyID = value.replyTo, let original = state.messages[replyID] {
                    let excerpt = original.text.replacingOccurrences(of: "\n", with: " ").prefix(120)
                    content = "↩︎ 回复 \(name(for: original.author))：\(excerpt)\n\(body)"
                } else if value.replyTo != nil {
                    content = "↩︎ 回复一条暂不可用的消息\n\(body)"
                } else { content = body }
            case .photo(let asset):
                content = asset.manifest.kind.hasPrefix("video/") ? "[视频]"
                    : asset.manifest.kind.hasPrefix("audio/") ? "[语音]" : "[照片]"
            }
            return "[\(time)] \(name(for: entry.author))：\(content)"
        }.joined(separator: "\n\n")
    }
    private func shareSelectedChat() {
        let entries = chatEntries.filter { selectedChatEntries.contains($0.id) }
        guard !entries.isEmpty else { return }
        sharePayload = ChatSharePayload(items: [chatExportText(for: entries)])
    }
    private func exportAllChat() {
        let text = chatExportText(for: chatEntries)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("我们的对话.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            sharePayload = ChatSharePayload(items: [url])
        } catch {
            failure = "暂时无法生成对话文件，请重试。"
        }
    }
    private func createBackup() {
        backupBusy = true
        Task {
            defer { backupBusy = false }
            do {
                let artifact = try await createEncryptedBackup()
                backupRecoveryKey = artifact.recoveryKey
                backupPreview = artifact.preview
                // Share only the encrypted file. The recovery key is copied separately.
                sharePayload = ChatSharePayload(items: [artifact.fileURL])
            } catch {
                failure = "未能创建备份：\(error.localizedDescription)"
            }
        }
    }
    private func verifySelectedBackup() {
        guard let url = backupVerificationURL else { return }
        backupBusy = true
        Task {
            defer { backupBusy = false }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                backupPreview = try await verifyEncryptedBackup(url, backupVerificationKey)
                showingBackupVerifier = false
            } catch {
                failure = "备份文件、恢复密钥或完整性校验不通过。"
            }
        }
    }
    private func affectionText(_ kind: AffectionKind) -> String {
        switch kind {
        case .hug: "\(peerName)给了你一个抱抱"
        case .missYou: "\(peerName)想你了"
        case .kiss: "\(peerName)亲了你一下"
        case .appreciation: "\(peerName)想对你说：辛苦啦"
        }
    }
    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = chatEntries.last?.id else { return }
        DispatchQueue.main.async {
            if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            else { proxy.scrollTo(id, anchor: .bottom) }
        }
    }
    @ViewBuilder private func messageBody(_ message: Message) -> some View {
        if let replyID = message.replyTo {
            VStack(alignment: .leading, spacing: 8) {
                if let original = state.messages[replyID] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(for: original.author)).font(.caption2.weight(.semibold))
                        Text(original.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Capsule().fill(SpaceStyle.accent).frame(width: 3) }
                } else {
                    Text("原消息暂不可用").font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Capsule().fill(SpaceStyle.accent).frame(width: 3) }
                }
                messageContent(message.text, parseLegacyQuote: false)
            }
        } else {
            messageContent(message.text, parseLegacyQuote: true)
        }
    }

    @ViewBuilder private func messageContent(_ text: String, parseLegacyQuote: Bool) -> some View {
        if let stickerID = StickerReference.stickerID(from: text) {
            if let sticker = stickerLibrary.sticker(id: stickerID) {
                LocalStickerBubble(sticker: sticker)
            } else {
                Label("表情库正在准备或版本不一致", systemImage: "face.dashed")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 150, height: 100)
            }
        } else {
            let pieces = text.components(separatedBy: "\n\n")
            if parseLegacyQuote, let first = pieces.first, first.hasPrefix("> "), pieces.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(first.dropFirst(2))).font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 8).overlay(alignment: .leading) { Capsule().fill(SpaceStyle.accent).frame(width: 3) }
                    Text(pieces.dropFirst().joined(separator: "\n\n")).textSelection(.enabled)
                }
            } else {
                Text(text).textSelection(.enabled)
            }
        }
    }

    private func setReaction(_ reaction: ChatReaction?, targetID: UUID) {
        Task {
            do { try await save(.chatReaction(ChatReactionContent(targetID: targetID, reaction: reaction)), targetID) }
            catch { failure = "回应没有保存，请重试。" }
        }
    }

    @ViewBuilder private func reactionMenu(targetID: UUID) -> some View {
        Menu("回应", systemImage: "face.smiling") {
            ForEach(ChatReaction.allCases, id: \.self) { reaction in
                Button(reaction.symbol) { setReaction(reaction, targetID: targetID) }
            }
        }
        if state.chatReactions[targetID]?[localID]?.reaction != nil {
            Button("取消回应", systemImage: "xmark.circle") { setReaction(nil, targetID: targetID) }
        }
    }

    @ViewBuilder private func reactionStrip(targetID: UUID) -> some View {
        let values = (state.chatReactions[targetID] ?? [:]).values
            .filter { $0.reaction != nil }
            .sorted { $0.author.uuidString < $1.author.uuidString }
        if !values.isEmpty {
            HStack(spacing: 4) {
                ForEach(values, id: \.author) { value in
                    if let reaction = value.reaction {
                        Text(reaction.symbol)
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(value.author == localID ? SpaceStyle.accent.opacity(0.16) : SpaceStyle.softSurface,
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(SpaceStyle.border, lineWidth: 1))
                            .accessibilityLabel("\(name(for: value.author))的回应：\(reaction.symbol)")
                    }
                }
            }
        }
    }

    private func sendSelectedPhotos(_ selections: [PhotosPickerItem]) async {
        photoSending = true
        defer { photoSending = false; selectedChatPhotos = [] }
        for selection in selections {
            do {
                guard let bytes = try await selection.loadTransferable(type: Data.self) else { throw SpaceError.invalidInput }
                let photo = try PhotoImport.prepare(bytes)
                try await savePhoto(photo.jpeg, photo.width, photo.height)
            } catch {
                failure = error as? SpaceError == .capacity
                    ? "其中一张照片处理后仍超过 2 MB，其他可读取照片已继续发送。"
                    : "其中一张照片读取或保存失败，其他可读取照片已继续发送。"
            }
        }
    }
    private func sendCapturedPhoto(_ bytes: Data) async {
        photoSending = true
        defer { photoSending = false }
        do {
            let photo = try PhotoImport.prepare(bytes)
            try await savePhoto(photo.jpeg, photo.width, photo.height)
        } catch {
            failure = error as? SpaceError == .capacity ? "照片处理后仍超过 2 MB，请重试。" : "无法使用这张照片，请重试。"
        }
    }
    private func sendSelectedVideo(_ selection: PhotosPickerItem) async {
        photoSending = true
        defer { photoSending = false; selectedChatVideo = nil }
        do {
            guard let picked = try await selection.loadTransferable(type: PickedVideo.self) else { throw SpaceError.invalidInput }
            defer { try? FileManager.default.removeItem(at: picked.url) }
            let video = try await VideoImport.prepare(picked.url)
            let kind = selection.supportedContentTypes.contains(where: { $0.conforms(to: .mpeg4Movie) })
                ? "video/mp4" : "video/quicktime"
            try await saveVideo(video.data, kind, video.width, video.height)
        } catch {
            failure = error as? SpaceError == .capacity
                ? "视频需在 30 秒、25 MB 以内。"
                : "无法读取或发送这个视频，请换一个再试。"
        }
    }
    private func sendSticker(_ sticker: InstalledSticker) async {
        photoSending = true
        defer { photoSending = false }
        do {
            if stickerLibrary.isSharedBuiltIn(sticker) {
                guard let text = StickerReference.message(for: sticker.id) else { throw SpaceError.invalidInput }
                try await save(.message(text: text), UUID())
            } else {
                // User-imported packs may differ between phones, so retain the full-media fallback.
                let bytes = try Data(contentsOf: sticker.mediaURL, options: .mappedIfSafe)
                try await saveSticker(bytes, sticker.record.mediaType, sticker.record.width, sticker.record.height)
            }
        } catch {
            failure = "表情发送失败，请稍后重试。"
        }
    }
    private func loadEarlierChat(using proxy: ScrollViewProxy, currentFirst: UUID?) {
        guard !loadingEarlierChat, chatVisibleLimit < chatEntries.count else { return }
        loadingEarlierChat = true
        let anchor = currentFirst
        Task { @MainActor in
            chatVisibleLimit = min(chatEntries.count, chatVisibleLimit + 80)
            await Task.yield()
            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            loadingEarlierChat = false
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text(syncStatus)
                Spacer()
                Button { Task { await retry() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("同步")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(card, in: Capsule())
            .overlay(Capsule().strokeBorder(SpaceStyle.border, lineWidth: 1))
            .padding(.horizontal, 18).padding(.top, 10)
            if chatEntries.isEmpty {
                ContentUnavailableView("日常的小事，都放在这里", systemImage: "bubble.left.and.text.bubble.right", description: Text("只有你和伴侣的对话。"))
            } else {
                let entries = visibleChatEntries
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        if chatEntries.count > entries.count {
                            Button {
                                loadEarlierChat(using: proxy, currentFirst: entries.first?.id)
                            } label: {
                                if loadingEarlierChat { ProgressView().controlSize(.small) }
                                else { Label("加载更早消息", systemImage: "clock.arrow.circlepath") }
                            }
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                            .onAppear { loadEarlierChat(using: proxy, currentFirst: entries.first?.id) }
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            VStack(spacing: 12) {
                            if showsDateDivider(at: index, in: entries) {
                                Text(dateDividerTitle(for: entry))
                                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(SpaceStyle.softSurface, in: Capsule())
                                    .frame(maxWidth: .infinity)
                            }
                            HStack(alignment: .bottom, spacing: 10) {
                                if entry.author == localID { Spacer(minLength: 36) }
                                if entry.author != localID {
                                    ProfileAvatar(name: name(for: entry.author), photoID: avatarID(for: entry.author),
                                                  load: loadPhoto, refresh: photoRefresh, size: 34)
                                }
                                VStack(alignment: entry.author == localID ? .trailing : .leading, spacing: 6) {
                                    Text(name(for: entry.author)).font(.caption2).foregroundStyle(.secondary)
                                    switch entry.content {
                                    case .text(let message):
                                        if StickerReference.stickerID(from: message.text) != nil {
                                            messageBody(message)
                                                .contextMenu {
                                                    reactionMenu(targetID: message.id)
                                                }
                                        } else {
                                            messageBody(message).padding(14)
                                                .background(entry.author == localID ? SpaceStyle.accent.opacity(0.14) : card,
                                                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                    .strokeBorder(entry.author == localID ? SpaceStyle.accent.opacity(0.10) : SpaceStyle.border, lineWidth: 1))
                                                .contextMenu {
                                                    Button("复制", systemImage: "doc.on.doc") {
                                                        UIPasteboard.general.string = message.text
                                                    }
                                                    Button("引用", systemImage: "quote.bubble") { quotedMessage = message; chatFocused = true }
                                                    reactionMenu(targetID: message.id)
                                                    Button("加入共同回忆", systemImage: "bookmark") { remember(id: message.id, title: "收藏的对话", text: message.text, date: Date()) }
                                                }
                                        }
                                    case .photo(let asset):
                                        if asset.manifest.kind.hasPrefix("audio/") {
                                            AudioBubble(id: asset.id, load: loadPhoto, refresh: photoRefresh,
                                                        interrupted: interruptedMediaIDs.contains(asset.id),
                                                        progress: { await mediaProgress(asset.id) },
                                                        retry: { await retryMedia(asset.id) })
                                                .contextMenu { reactionMenu(targetID: asset.id) }
                                        } else if asset.manifest.kind.hasPrefix("video/") {
                                            VideoBubble(id: asset.id, kind: asset.manifest.kind,
                                                        width: asset.manifest.width, height: asset.manifest.height,
                                                        load: loadPhoto, refresh: photoRefresh,
                                                        interrupted: interruptedMediaIDs.contains(asset.id),
                                                        progress: { await mediaProgress(asset.id) },
                                                        retry: { await retryMedia(asset.id) })
                                                .contextMenu { reactionMenu(targetID: asset.id) }
                                        } else {
                                        PhotoBubble(id: asset.id, kind: asset.manifest.kind,
                                                    load: loadPhoto, refresh: photoRefresh,
                                                    interrupted: interruptedMediaIDs.contains(asset.id),
                                                    progress: { await mediaProgress(asset.id) },
                                                    retry: { await retryMedia(asset.id) },
                                                    preview: {
                                                        photoPreview = PhotoPreview(photoIDs: chatPhotoIDs,
                                                                                    selectedID: asset.id,
                                                                                    seedImage: $0)
                                                    })
                                            .contextMenu {
                                                reactionMenu(targetID: asset.id)
                                                Button("加入共同回忆", systemImage: "bookmark") {
                                                    rememberPhoto(asset.id)
                                                }
                                            }
                                        }
                                    }
                                    reactionStrip(targetID: entry.id)
                                    if let createdAt = entryCreatedAt(entry) {
                                        Text(createdAt.formatted(date: .omitted, time: .shortened))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    if entry.author == localID {
                                        if case .photo = entry.content {
                                            Text(deliveries[entry.version.event] == .delivered ? "已送达" : "等待安全传输")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        } else {
                                            Text(deliveryTitle(entry.version.event)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if entry.author == localID {
                                    ProfileAvatar(name: name(for: entry.author), photoID: avatarID(for: entry.author),
                                                  load: loadPhoto, refresh: photoRefresh, size: 34)
                                }
                                if entry.author != localID { Spacer(minLength: 36) }
                            }
                            }
                            .padding(.leading, selectingChat ? 34 : 0)
                            .overlay(alignment: .leading) {
                                if selectingChat {
                                    Image(systemName: selectedChatEntries.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(selectedChatEntries.contains(entry.id) ? SpaceStyle.accent : .secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard selectingChat else { return }
                                if !selectedChatEntries.insert(entry.id).inserted { selectedChatEntries.remove(entry.id) }
                            }
                            .id(entry.id)
                        }
                    }.padding(20)
                }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.immediately)
                    .onAppear { scrollToLatest(proxy, animated: false) }
                    .onChange(of: chatEntries.last?.id) { _, _ in scrollToLatest(proxy, animated: true) }
                    .onChange(of: chatFocused) { _, focused in if focused { scrollToLatest(proxy, animated: true) } }
                }
            }
            HStack(spacing: 8) {
                ForEach(AffectionKind.allCases, id: \.self) { kind in
                    Button { sendFeeling(kind) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: kind.symbol).font(.subheadline.weight(.semibold))
                            Text(kind == .missYou ? "想你" : kind.rawValue)
                                .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(SpaceStyle.border, lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel(kind.rawValue)
                }
            }.padding(.horizontal, 16).padding(.top, 8)
            if let affectionStatus { Text(affectionStatus).font(.caption).foregroundStyle(.secondary).padding(.top, 6) }
            if let quotedMessage {
                HStack(spacing: 10) {
                    Image(systemName: "quote.bubble").foregroundStyle(SpaceStyle.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("回复 \(name(for: quotedMessage.author))").font(.caption.weight(.semibold))
                        Text(quotedMessage.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { self.quotedMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("取消引用")
                }.padding(.horizontal, 18).padding(.top, 8)
            }
            VStack(spacing: 8) {
                HStack(spacing: 22) {
                    Button { showingStickerLibrary = true } label: {
                        Label("表情", systemImage: "face.smiling")
                    }.accessibilityLabel("表情库")
                    Button { showingChatCamera = true } label: {
                        Label("拍照", systemImage: "camera")
                    }.disabled(photoSending).accessibilityLabel("拍照")
                    PhotosPicker(selection: $selectedChatPhotos, maxSelectionCount: 9,
                                 selectionBehavior: .ordered, matching: .images) {
                        Label("相册", systemImage: "photo.on.rectangle")
                    }.disabled(photoSending).accessibilityLabel("从相册选择").accessibilityIdentifier("chat-photo-picker")
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SpaceStyle.accent)
                .padding(.horizontal, 8)

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("想和你说…", text: $draft, axis: .vertical).focused($chatFocused).lineLimit(1...6)
                        .padding(14).background(card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(SpaceStyle.border, lineWidth: 1))
                        .accessibilityIdentifier("message-draft")
                    Button {
                    let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let payload: EventPayload = quotedMessage.map {
                        .messageV2(MessageContent(text: raw, replyTo: $0.id))
                    } ?? .message(text: raw)
                    sending = true
                    Task {
                        do { try await save(payload, UUID()); draft = ""; quotedMessage = nil; chatFocused = false }
                        catch { failure = "内容未保存，请重试。输入仍保留。" }
                        sending = false
                    }
                    } label: { Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white).frame(width: 46, height: 46).background(SpaceStyle.accent, in: Circle()) }
                        .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送")
                        .opacity(sending ? 0.45 : 1)
                }
            }.padding(16)
        }.background(paper)
    }

    private var wishes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SpaceIntro(symbol: "star", title: "把愿望慢慢实现", detail: "想一起做的事，都值得认真记下。")
                Picker("愿望与清单", selection: $wishSection) { Text("愿望").tag(0); Text("双人清单").tag(1) }.pickerStyle(.segmented)
                if wishSection == 0 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach([WishStatus.active, .fulfilled, .deferred, .archived], id: \.self) { status in
                            Button(statusTitle(status)) { wishFilter = status }.buttonStyle(.bordered).tint(wishFilter == status ? SpaceStyle.accent : .secondary)
                        } }
                    }
                    let items = state.wishes.values.filter { $0.status == wishFilter }.sorted { $0.statusVersion > $1.statusVersion }
                    if items.isEmpty { ContentUnavailableView("这里还没有愿望", systemImage: "star", description: Text("一起吃饭、散步，或去想去的地方。")) }
                    ForEach(items, id: \.id) { wish in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(wish.text).font(.title3.weight(.medium))
                            Text("来自\(name(for: wish.creator))").font(.caption).foregroundStyle(.secondary)
                            if wish.status == .fulfilled {
                                if let date = wish.completedAt {
                                    Text("实现于 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("这份愿望未记录完成时间").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Menu("记下进展") {
                                    ForEach([WishStatus.active, .fulfilled, .deferred, .archived], id: \.self) { status in
                                        Button(statusTitle(status)) { submit(.wishStatus(status), id: wish.id) }
                                    }
                                }
                                if wish.status == .fulfilled {
                                    Spacer()
                                    Button("留作回忆") { remember(id: wish.id, title: wish.text, text: wish.completedAt == nil ? "一个已经实现的小愿望。日期为收藏日期，原完成时间未记录。" : "一个已经实现的小愿望。", date: wish.completedAt ?? Date()) }
                                }
                            }.font(.subheadline)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).spacePanel()
                    }
                    NavigationLink { reminderSettings } label: {
                        Label("愿望提醒", systemImage: "bell").frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18).background(SpaceStyle.sage.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SpaceStyle.sage.opacity(0.14), lineWidth: 1))
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(ListCategory.allCases, id: \.self) { item in
                        Button(item.rawValue) { category = item }.buttonStyle(.bordered).tint(category == item ? SpaceStyle.accent : .secondary)
                    } } }
                    let items = state.journal.checklist.values.filter { !$0.value.deleted && $0.value.category == category }.sorted { $0.version < $1.version }
                    if items.isEmpty { ContentUnavailableView("一起收集小想法", systemImage: "checklist", description: Text("从一个想去、想吃、想做的地方开始。")) }
                    ForEach(items) { record in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                var value = record.value; value.completed.toggle(); submit(.journal(.checklist(value)), id: record.id)
                            } label: { Image(systemName: record.value.completed ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(SpaceStyle.sage).frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel(record.value.completed ? "恢复未完成：\(record.value.text)" : "完成：\(record.value.text)")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.value.text).strikethrough(record.value.completed)
                                if let dueAt = record.value.dueAt {
                                    Label(dueAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                                        .font(.caption).foregroundStyle(dueAt < Date() && !record.value.completed ? SpaceStyle.accent : .secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                            Menu {
                                Button("编辑") { composing = .checklist(record, category) }
                                if record.value.completed { Button("留作回忆") { remember(id: record.id, title: record.value.text, text: "一起完成的一件小事。", date: Date()) } }
                                Button("删除", role: .destructive) { var value = record.value; value.deleted = true; submit(.journal(.checklist(value)), id: record.id) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("清单操作")
                        }.padding(14).spacePanel(radius: 22)
                    }
                }
            }.padding(20)
        }.background(paper)
    }

    private var memories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SpaceIntro(symbol: "photo.on.rectangle.angled", title: "把日子珍藏起来", detail: "一些舍不得忘的小事，留给两个人。")
                Picker("回忆内容", selection: $memorySection) { Text("共同回忆").tag(0); Text("时间胶囊").tag(1) }.pickerStyle(.segmented)
                if memorySection == 0 {
                    let items = state.journal.memories.values.filter { !$0.value.deleted }.sorted { $0.value.date > $1.value.date }
                    if items.isEmpty { ContentUnavailableView("给日子留一页", systemImage: "book", description: Text("写一段回忆，或把喜欢的对话和实现的愿望留在这里。")) }
                    ForEach(items) { record in
                        VStack(alignment: .leading, spacing: 12) {
                            Button { selectedMemory = record.id } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(record.value.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    Text(record.value.title).font(.title3.weight(.medium)).foregroundStyle(.primary)
                                    if !record.value.text.isEmpty {
                                        Text(record.value.text).lineLimit(3).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if let mediaID = record.value.mediaID {
                                PhotoBubble(id: mediaID, kind: "image/jpeg", load: loadPhoto, refresh: photoRefresh,
                                            interrupted: interruptedMediaIDs.contains(mediaID),
                                            progress: { await mediaProgress(mediaID) },
                                            retry: { await retryMedia(mediaID) },
                                            preview: { photoPreview = PhotoPreview(photoIDs: [mediaID], selectedID: mediaID, seedImage: $0) })
                            }
                            Menu("整理回忆") {
                                Button("编辑") { composing = .memory(record) }
                                Button("移除共同回忆", role: .destructive) { var value = record.value; value.deleted = true; submit(.journal(.memory(value)), id: record.id) }
                            }.font(.caption)
                        }.padding(22).spacePanel()
                    }
                } else {
                    Text("写给未来的对方。封存后，到约定的时间再看。").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(capsuleDrafts) { value in
                        VStack(alignment: .leading, spacing: 12) {
                            Label("仅在本机的草稿", systemImage: "pencil.line").font(.caption).foregroundStyle(.secondary)
                            Text(value.title.isEmpty ? "还没写完的心里话" : value.title).font(.headline)
                            Button("继续写") { editingCapsule = value }
                            Button("丢弃草稿", role: .destructive) {
                                Task { do { try await discardCapsuleDraft(value.id) } catch { failure = error.localizedDescription } }
                            }.font(.caption)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).spacePanel()
                    }
                    let items = state.journal.capsules.values.filter { $0.value.companionOf == nil }.sorted { $0.value.opensAt < $1.value.opensAt }
                    if items.isEmpty { ContentUnavailableView("把一句话留给未来", systemImage: "envelope.badge.shield.half.filled", description: Text("写下文字，约定一个开启时刻。")) }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ForEach(items) { record in capsuleCard(record, now: context.date) }
                    }
                    DisclosureGroup("关于封存与隐私") {
                        Text("提前加密送达后，内容由 App 按设备时间开放。此限制无法防止改时钟或篡改程序提前查看。").font(.footnote).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }
            }.padding(20)
        }.background(paper)
    }

    private func capsuleCard(_ record: JournalRecord<CapsuleContent>, now: Date) -> some View {
        let cancelled = state.journal.isCancelled(record)
        let parts = state.journal.contributions(to: record.id)
        let readable = parts.filter { state.journal.canOpen($0, now: now) }
        let ready = !readable.isEmpty
        let duet = record.value.partnerSlotID != nil
        return VStack(alignment: .leading, spacing: 14) {
            Label(ready ? (readable.allSatisfy { openedCapsules.contains($0.id) } ? "已打开" : "到了约定的时刻") : cancelled ? "已取消" : "已封存", systemImage: ready ? "envelope.open" : "lock")
                .font(.caption).foregroundStyle(SpaceStyle.accent)
            Text(record.value.title).font(.title3.weight(.medium))
            Text(duet ? "两个人各写一份 · 到时一起看" : record.author == localID ? "写给\(peerName)" : "来自\(name(for: record.author))").font(.caption).foregroundStyle(.secondary)
            if duet { Text("已封存 \(parts.filter { !state.journal.isCancelled($0) }.count) / 2 份").font(.caption).foregroundStyle(.secondary) }
            Text(record.value.opensAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
            if record.author == localID {
                let photoPending = record.value.mediaID.flatMap { state.media[$0] }
                    .map { deliveries[$0.version.event] != .delivered } ?? (record.value.mediaID != nil)
                Text(photoPending ? "等待安全传输" : deliveryTitle(record.version.event))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ready {
                Button(readable.allSatisfy { openedCapsules.contains($0.id) } ? "再看一遍" : "打开胶囊") {
                    Task {
                        do { for part in readable { try await openCapsule(part.id) }; selectedCapsule = record.id }
                        catch { failure = error.localizedDescription }
                    }
                }.buttonStyle(.bordered)
            }
            if !cancelled, now < record.value.opensAt, record.author != localID,
               let slot = record.value.partnerSlotID, state.journal.capsules[slot] == nil {
                Button("写下我的一份") {
                    Task {
                        do { editingCapsule = try await prepareCapsuleDraft(CapsuleDraft(id: slot, title: record.value.title, opensAt: record.value.opensAt, companionOf: record.id)) }
                        catch { failure = error.localizedDescription }
                    }
                }.buttonStyle(.bordered)
            }
            if let own = parts.first(where: { $0.author == localID && !state.journal.isCancelled($0) }), now < own.value.opensAt {
                Menu("管理胶囊") { Button("取消我的封存", role: .destructive) { submit(.journal(.cancelCapsule), id: own.id) } }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).spacePanel()
    }

    private var together: some View {
        ScrollViewReader { scroll in
        List {
            Section {
                Button { editingProfile = true } label: {
                    HStack(spacing: 8) {
                        ProfileAvatar(name: name(for: localID), photoID: avatarID(for: localID),
                                      load: loadPhoto, refresh: photoRefresh, size: 46)
                        Image(systemName: "heart.fill").font(.caption).foregroundStyle(SpaceStyle.accent)
                        ProfileAvatar(name: peerName, photoID: peerAvatarID,
                                      load: loadPhoto, refresh: photoRefresh, size: 46)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("两个人，更好的每一天").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .lineLimit(1).minimumScaleFactor(0.82)
                            Text("把平凡日子，过成特别的我们").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).spacePanel()
                }.buttonStyle(.plain).accessibilityIdentifier("edit-my-profile")
            }
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        CycleOverviewCard(entry: privateCycle, projection: state.cycle, isOwner: isCycleOwner)
                    }
                    Divider()
                    NavigationLink {
                        CycleDetailView(entry: privateCycle, projection: state.cycle, isOwner: isCycleOwner, save: cycle)
                    } label: {
                        Text("查看与设置周期").font(.subheadline.weight(.medium)).foregroundStyle(SpaceStyle.accent)
                    }.accessibilityIdentifier("cycle-details")
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).spacePanel()
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Section {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    AnniversaryOverviewCard(records: state.journal.anniversaries, editing: $editingAnniversary,
                                            activeWishCount: state.wishes.values.filter { $0.status == .active }.count,
                                            showWishes: { tab = 1 })
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading).spacePanel()
                }
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Section {
                Button { withAnimation { scroll.scrollTo("privacy", anchor: .top) } } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            Image(systemName: "lock").font(.title3).foregroundStyle(SpaceStyle.sage)
                                .frame(width: 44, height: 44).background(SpaceStyle.sage.opacity(0.10), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text("隐私与连接").font(.headline).foregroundStyle(.primary)
                                Text("守护我们的私密空间").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Label("只有我们两个人", systemImage: "person.2")
                            Label("数据安全", systemImage: "checkmark.shield")
                        }.font(.caption).foregroundStyle(SpaceStyle.sage)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).spacePanel()
                }.buttonStyle(.plain).accessibilityIdentifier("privacy-shortcut")
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Section("两个人") {
                HStack(spacing: 12) {
                    ProfileAvatar(name: name(for: localID), photoID: avatarID(for: localID), load: loadPhoto, refresh: photoRefresh, size: 48)
                    Text(name(for: localID))
                    Spacer()
                    Text("我").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ProfileAvatar(name: peerName, photoID: peerAvatarID, load: loadPhoto, refresh: photoRefresh, size: 48)
                    Text(peerName)
                    Spacer()
                    Text("伴侣").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink { reminderSettings } label: { Label("愿望提醒", systemImage: "bell") }
            }
            Section("隐私与连接") {
                Label("本地数据加密保存", systemImage: "lock.doc")
                Label("共享内容端到端加密", systemImage: "lock.shield")
                Button(appLockEnabled ? "关闭应用锁" : "开启应用锁") {
                    Task {
                        do { try await configureAppLock(!appLockEnabled) }
                        catch { failure = "应用锁设置未更改。请完成设备验证；开启前需先设置设备密码。" }
                    }
                }.accessibilityIdentifier("app-lock-setting")
                Text(appLockEnabled ? "打开 App 时需要使用设备认证。" : "可选：打开 App 时使用面容 ID、触控 ID 或设备密码。")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("同步", value: syncStatus)
                Text("我的设备标识").font(.caption).foregroundStyle(.secondary)
                Text(localID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                if let peerDeviceID {
                    Text("伴侣设备标识").font(.caption).foregroundStyle(.secondary)
                    Text(peerDeviceID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let pairingCode {
                    LabeledContent("身份绑定", value: "已加密绑定")
                    Text("双方身份核对码").font(.caption).foregroundStyle(.secondary)
                    Text(pairingCode).font(.headline.monospaced()).textSelection(.enabled)
                    Text("请与伴侣在各自设备上逐组核对。若号码不同，请停止共享；更换设备后也需要重新核验。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("换机前请先在每台手机分别创建自己的加密备份。恢复入口只会出现在全新、尚未配对的安装中。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let showPairingFinal {
                    Button("重新显示最终配对确认") { showPairingFinal() }
                    Text("如果伴侣的设备仍停在配对页，可把确认资料再次交给对方。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("解除配对", role: .destructive) { showRevokeConfirmation = true }
                    .disabled(revoking).accessibilityIdentifier("pair-revoke")
                Text("解除会停止这段配对的同步；本机和伴侣设备已保存的内容不会自动删除。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.id("privacy")
            Section("加密备份") {
                Button {
                    createBackup()
                } label: { Label(backupBusy ? "正在生成…" : "创建完整加密备份", systemImage: "externaldrive.badge.lock") }
                    .disabled(backupBusy)
                    .accessibilityIdentifier("create-encrypted-backup")
                Button { showingBackupImporter = true } label: {
                    Label("校验已有备份", systemImage: "checkmark.shield")
                }.disabled(backupBusy)
                if !backupRecoveryKey.isEmpty {
                    Text("本次恢复密钥").font(.caption).foregroundStyle(.secondary)
                    Text(backupRecoveryKey).font(.caption.monospaced()).textSelection(.enabled)
                    Button("复制恢复密钥") { UIPasteboard.general.string = backupRecoveryKey }
                    Text("请把恢复密钥与 .couplebackup 文件分开保存。丢失密钥后无法恢复。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let backupPreview {
                    Text("\(backupPreview.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(backupPreview.messageCount) 条消息 · \(backupPreview.photoCount) 个媒体 · \(backupPreview.wishCount) 个愿望")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text(backupStatus).font(.footnote).foregroundStyle(.secondary)
                Text("每台手机都应创建并保留自己的备份。这里不会覆盖当前配对；恢复入口只会出现在全新、尚未配对的安装中。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("后台通知") {
                Toggle("新消息", isOn: $messagePushEnabled)
                Toggle("收到新愿望", isOn: $wishPushEnabled)
                Toggle("小心意", isOn: $pushEnabled)
                Toggle("前台触觉反馈", isOn: $affectionHaptics)
                Button("保存后台通知设置") { Task { do { try await configurePush(pushEnabled, messagePushEnabled, wishPushEnabled) } catch { failure = error.localizedDescription } } }
                Text(pushStatus).font(.footnote).foregroundStyle(.secondary)
                Text("锁屏只显示新消息、新愿望或小心意的通用提示。姓名与内容要打开 App 才能看到；声音与触觉遵循系统设置。小心意 15 分钟后过期，不进入聊天记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("时间胶囊") {
                Toggle("到期时提醒我", isOn: $capsuleRemindersEnabled)
                Button("保存胶囊提醒设置") {
                    Task { do { try await configureCapsuleReminders(capsuleRemindersEnabled) } catch { failure = error.localizedDescription } }
                }
                Text(capsuleReminderStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section("纪念日") {
                Toggle("提醒重要的日子", isOn: $anniversaryRemindersEnabled)
                Picker("提前提醒", selection: $anniversaryReminderDays) {
                    Text("当天").tag(0)
                    Text("提前 1 天及当天").tag(1)
                    Text("提前 3 天及当天").tag(3)
                    Text("提前 7 天及当天").tag(7)
                }
                Button("保存纪念日提醒设置") {
                    Task { do { try await configureAnniversaryReminders(anniversaryRemindersEnabled, anniversaryReminderDays) }
                           catch { failure = error.localizedDescription } }
                }
                Text(anniversaryReminderStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }.listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 52)
            .scrollContentBackground(.hidden).background(paper)
            .sheet(item: $editingAnniversary) { draft in
                AnniversaryEditor(draft: draft, exists: state.journal.anniversaries[draft.id]?.value.deleted == false, save: save)
                    .equatable()
            }
        }
    }

    private var reminderSettings: some View {
        Form {
            Section {
                Toggle("接收愿望提醒", isOn: $remindersEnabled)
                Picker("随机时间窗口", selection: $reminderDays) {
                    ForEach([1, 3, 7, 30], id: \.self) { Text("未来 \($0) 天").tag($0) }
                    if ![1, 3, 7, 30].contains(reminderDays) { Text("自定义：未来 \(reminderDays) 天").tag(reminderDays) }
                }.accessibilityIdentifier("wish-window-picker")
                Stepper("自定义：未来 \(reminderDays) 天", value: $reminderDays, in: 1...30)
                    .accessibilityIdentifier("wish-custom-days")
                Toggle("避开静默时段", isOn: $quietEnabled)
                if quietEnabled {
                    Picker("静默开始", selection: $quietStart) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker("静默结束", selection: $quietEnd) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Text("按本机时区安排愿望提醒。修改时段或在新时区打开 App 后，会重排未来提醒；不影响胶囊和小心意。开始与结束不能相同。").font(.footnote).foregroundStyle(.secondary)
                }
                Button("保存提醒设置") {
                    Task { do { try await configureReminders(remindersEnabled, reminderDays, QuietHours(enabled: quietEnabled, startHour: quietStart, endHour: quietEnd)) } catch { failure = error.localizedDescription } }
                }.disabled(quietEnabled && quietStart == quietEnd)
            } footer: { Text("愿望收到后立即可见。提醒由你的设备选择时间，不会告诉对方。关闭提醒不影响接收内容。") }
            Section { Text(reminderStatus).font(.subheadline) }
        }.scrollContentBackground(.hidden).background(paper).navigationTitle("愿望提醒")
    }

    private func submit(_ payload: EventPayload, id: UUID) {
        Task { do { try await save(payload, id) } catch { failure = "未能保存，请稍后重试。" } }
    }
    private func route(_ destination: NotificationDestination) async {
        defer { consumeNotification() }
        if destination.kind == .message || destination.kind == .wish {
            await clearRemoteNotifications(for: destination.kind)
        }
        selectedMemory = nil; selectedWish = nil; selectedCapsule = nil
        switch destination.kind {
        case .message:
            tab = 0
        case .anniversary:
            tab = 3
        case .wish:
            tab = 1; wishSection = 0
            guard let objectID = destination.objectID else { return }
            guard let wish = state.wishes[objectID] else { failure = "这条愿望尚未在本机找到，请同步后查看。"; return }
            wishFilter = wish.status
            do { try await openWishReminder(wish.id); selectedWish = wish.id } catch { failure = error.localizedDescription }
        case .capsule:
            tab = 2; memorySection = 1
            guard let objectID = destination.objectID else { return }
            let readable = state.journal.contributions(to: objectID).filter { state.journal.canOpen($0, now: Date()) }
            guard !readable.isEmpty else { failure = "这个胶囊尚未到期、已取消，或尚未同步到本机。"; return }
            do { for part in readable { try await openCapsule(part.id) }; selectedCapsule = objectID }
            catch { failure = error.localizedDescription }
        }
    }
    private func clearRemoteNotifications(for kind: NotificationDestination.Kind) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.trigger is UNPushNotificationTrigger &&
            $0.request.content.userInfo["destination"] as? String == kind.rawValue
        }.map(\.request.identifier))
        try? await center.setBadgeCount(0)
    }
    private func sendFeeling(_ kind: AffectionKind) {
        Task {
            do {
                let queued = try await sendAffection(kind)
                let text = queued ? "小心意已排入发送，不会留下聊天记录" : "刚刚已经送出这份心意"
                affectionStatus = text
                try? await Task.sleep(for: .seconds(4))
                if affectionStatus == text { affectionStatus = nil }
            } catch {
                failure = error as? SpaceError == .capacity ? "还有一些小心意等待对方接收，稍后再试吧。" : "小心意未能保存，请稍后再试。"
            }
        }
    }
    private func remember(id: UUID, title: String, text: String, date: Date) {
        // Reuse the source ID to make the action idempotent across both devices.
        if let old = state.journal.memories[id] {
            if old.value.deleted {
                var restored = old.value; restored.deleted = false
                submit(.journal(.memory(restored)), id: id)
            }
        } else {
            submit(.journal(.memory(MemoryContent(title: String(title.prefix(120)), text: text, date: date, sourceID: id))), id: id)
        }
        tab = 2; memorySection = 0
    }
    private func rememberPhoto(_ id: UUID) {
        if let old = state.journal.memories[id] {
            if old.value.deleted {
                var restored = old.value; restored.deleted = false
                submit(.journal(.memory(restored)), id: id)
            }
        } else {
            let memory = MemoryContent(title: "一起留下的照片", text: "", date: Date(),
                                       sourceID: id, mediaID: id)
            submit(.journal(.memory(memory)), id: id)
        }
        tab = 2; memorySection = 0
    }
    private func rememberCapsule(_ capsule: JournalRecord<CapsuleContent>) {
        if state.journal.memories[capsule.id] != nil {
            tab = 2; memorySection = 0; return
        }
        let memory = MemoryContent(title: capsule.value.title, text: capsule.value.text,
                                   date: capsule.value.opensAt, sourceID: capsule.id,
                                   mediaID: capsule.value.mediaID)
        submit(.journal(.memory(memory)), id: capsule.id)
        tab = 2; memorySection = 0
    }
    private func deliveryTitle(_ id: UUID) -> String {
        switch deliveries[id] { case .delivered: "已送达"; case .uploaded: "已发送 · 等待送达"; case .encrypted: "等待发送"; default: "保存在本机 · 待发送" }
    }
    private func statusTitle(_ status: WishStatus) -> String {
        switch status { case .active: "进行中"; case .fulfilled: "已实现"; case .deferred: "以后再说"; case .archived: "已归档" }
    }
}

private enum Composer: Identifiable {
    case wish, checklist(JournalRecord<ChecklistContent>?, ListCategory), memory(JournalRecord<MemoryContent>?)
    var id: String { switch self { case .wish: "wish"; case .checklist: "list"; case .memory: "memory" } }
    var title: String { switch self { case .wish: "写一个愿望"; case .checklist: "一起做的小事"; case .memory: "留下一段回忆" } }
}

private struct ContentComposer: View {
    let item: Composer
    let save: (EventPayload, UUID) async throws -> Void
    let saveMemoryWithPhoto: (MemoryContent, Data, Int, Int, UUID) async throws -> Void
    let saveMemoryWithVideo: (MemoryContent, Data, String, Int, Int, UUID) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var date = Date().addingTimeInterval(86_400)
    @State private var category: ListCategory = .eat
    @State private var hasDueDate = false
    @State private var dueAt = Date().addingTimeInterval(3_600)
    @State private var saving = false
    @State private var error: String?
    @State private var objectID = UUID()
    @State private var selectedMemoryPhoto: PhotosPickerItem?
    @State private var importedPhoto: (jpeg: Data, width: Int, height: Int)?
    @State private var selectedMemoryVideo: PhotosPickerItem?
    @State private var importedVideo: (data: Data, kind: String, width: Int, height: Int)?
    @State private var photoLoading = false
    @State private var showingCamera = false
    private var needsTitle: Bool { switch item { case .memory: true; default: false } }
    private var allowsEmptyText: Bool {
        if case .memory(let record) = item { return importedPhoto != nil || importedVideo != nil || record?.value.mediaID != nil }
        return false
    }
    var body: some View {
        NavigationStack {
            Form {
                if needsTitle { TextField("标题", text: $title).accessibilityIdentifier("content-title") }
                Section(needsTitle ? "想留下的话（可选）" : "内容") {
                    TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("content-body")
                }
                if case .checklist = item {
                    Picker("分类", selection: $category) { ForEach(ListCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("设置时间", isOn: $hasDueDate)
                    if hasDueDate { DatePicker("提醒时间", selection: $dueAt) }
                }
                if case .memory = item { DatePicker("这一天", selection: $date, displayedComponents: .date) }
                if case .memory(let record) = item {
                    Section("照片（可选）") {
                        if record?.value.mediaID != nil {
                            Label("已有附件，编辑会保留原附件", systemImage: "paperclip")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 20) {
                                Button { showingCamera = true } label: { Label("拍照", systemImage: "camera") }
                                    .buttonStyle(.bordered)
                                PhotosPicker(selection: $selectedMemoryPhoto, matching: .images) {
                                    Label("从相册选择", systemImage: "photo.on.rectangle")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let importedPhoto, let image = UIImage(data: importedPhoto.jpeg) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                Button("移除所选照片", role: .destructive) {
                                    self.importedPhoto = nil; selectedMemoryPhoto = nil
                                }
                            }
                            if importedVideo != nil {
                                Label("已选择短视频", systemImage: "video.fill")
                                Button("移除所选视频", role: .destructive) {
                                    importedVideo = nil; selectedMemoryVideo = nil
                                }
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.scrollContentBackground(.hidden).background(SpaceStyle.paper)
                .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { persist() }.disabled(saving || photoLoading || (!allowsEmptyText && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) }
                }
        }.tint(SpaceStyle.accent).interactiveDismissDisabled(saving)
            .sheet(isPresented: $showingCamera) {
                CameraPicker { bytes in
                    do {
                        importedPhoto = try PhotoImport.prepare(bytes)
                        importedVideo = nil; selectedMemoryVideo = nil; error = nil
                    }
                    catch { self.error = "无法使用这张照片，请重试。" }
                }
            }
            .onAppear {
                switch item {
                case .checklist(let record, let selected):
                    category = record?.value.category ?? selected; text = record?.value.text ?? ""; objectID = record?.id ?? objectID
                    hasDueDate = record?.value.dueAt != nil; dueAt = record?.value.dueAt ?? Date().addingTimeInterval(3_600)
                case .memory(let record):
                    title = record?.value.title ?? ""; text = record?.value.text ?? ""; date = record?.value.date ?? Date(); objectID = record?.id ?? objectID
                default: break
                }
            }
            .onChange(of: selectedMemoryPhoto) { _, selection in
                guard let selection else { return }
                photoLoading = true
                Task {
                    defer { photoLoading = false }
                    do {
                        guard let bytes = try await selection.loadTransferable(type: Data.self) else {
                            throw SpaceError.invalidInput
                        }
                        importedPhoto = try PhotoImport.prepare(bytes)
                        importedVideo = nil; selectedMemoryVideo = nil
                        error = nil
                    } catch {
                        self.error = error as? SpaceError == .capacity
                            ? "照片处理后仍超过 2 MB，请选择另一张。"
                            : "无法读取这张照片，请重试。"
                    }
                }
            }
            .onChange(of: selectedMemoryVideo) { _, selection in
                guard let selection else { return }
                photoLoading = true
                Task {
                    defer { photoLoading = false }
                    do {
                        guard let picked = try await selection.loadTransferable(type: PickedVideo.self) else { throw SpaceError.invalidInput }
                        defer { try? FileManager.default.removeItem(at: picked.url) }
                        let video = try await VideoImport.prepare(picked.url)
                        let kind = selection.supportedContentTypes.contains(where: { $0.conforms(to: .mpeg4Movie) })
                            ? "video/mp4" : "video/quicktime"
                        importedVideo = (video.data, kind, video.width, video.height)
                        importedPhoto = nil; selectedMemoryPhoto = nil; error = nil
                    } catch {
                        self.error = error as? SpaceError == .capacity ? "视频需在 30 秒、25 MB 以内。" : "无法读取这个视频，请重试。"
                    }
                }
            }
    }
    private func persist() {
        let payload: EventPayload
        let photo = importedPhoto
        let video = importedVideo
        var photoMemory: MemoryContent?
        switch item {
        case .wish: payload = .wishCreated(text: text)
        case .checklist(let record, _):
            payload = .journal(.checklist(ChecklistContent(text: text, category: category,
                completed: record?.value.completed ?? false, deleted: record?.value.deleted ?? false,
                dueAt: hasDueDate ? dueAt : nil)))
        case .memory(let record):
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let memory = MemoryContent(title: name.isEmpty ? (text.isEmpty ? "一起留下的照片" : "一起留下的一段话") : name,
                                       text: text, date: date,
                                       sourceID: photo == nil && video == nil ? record?.value.sourceID : objectID,
                                       mediaID: photo == nil && video == nil ? record?.value.mediaID : objectID)
            photoMemory = memory
            payload = .journal(.memory(memory))
        }
        saving = true
        Task {
            do {
                if let photo, let photoMemory {
                    try await saveMemoryWithPhoto(photoMemory, photo.jpeg, photo.width, photo.height, objectID)
                } else if let video, let photoMemory {
                    try await saveMemoryWithVideo(photoMemory, video.data, video.kind, video.width, video.height, objectID)
                } else {
                    try await save(payload, objectID)
                }
                dismiss()
            }
            catch { self.error = "未能保存，请检查内容长度和时间后重试。输入仍保留。" }
            saving = false
        }
    }
}
private struct VideoBubble: View {
    let id: UUID
    let kind: String
    let width: Int
    let height: Int
    let load: (UUID) async throws -> Data?
    let refresh: Date?
    var interrupted = false
    var progress: () async -> Double? = { nil }
    var retry: () async -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var transferProgress: Double?
    @State private var timedOut = false
    @State private var retryNonce = 0
    @State private var isVisible = true

    private var showsRetry: Bool { interrupted || timedOut }

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                VStack(spacing: 10) {
                    Label("视频传输已暂停", systemImage: "video")
                    if let transferProgress, transferProgress > 0 {
                        ProgressView(value: transferProgress).frame(width: 130)
                        Text("\(Int(transferProgress * 100))%").font(.caption2).monospacedDigit()
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 220, height: 150)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .onScrollVisibilityChange(threshold: 0.05) {
            isVisible = $0
            if !$0 { player?.pause() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
        .task(id: "\(scenePhase)-\(refresh?.timeIntervalSince1970 ?? 0)-\(retryNonce)") {
            guard scenePhase == .active else { return }
            if let data = try? await load(id) {
                do {
                    let ext = kind == "video/mp4" ? "mp4" : "mov"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("couple-\(id.uuidString).\(ext)")
                    try? FileManager.default.removeItem(at: url)
                    try data.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                    temporaryURL = url; player = AVPlayer(url: url); timedOut = false
                } catch { timedOut = true }
            }
        }
        .onDisappear {
            player?.pause(); player = nil
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            temporaryURL = nil
        }
        .accessibilityIdentifier("chat-video")
    }
}

private struct PhotoBubble: View {
    let id: UUID
    let kind: String
    let load: (UUID) async throws -> Data?
    let refresh: Date?
    var interrupted = false
    var progress: () async -> Double? = { nil }
    var retry: () async -> Void = {}
    let preview: (UIImage) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var jpeg: Data?
    @State private var saveStatus: String?
    @State private var isVisible = true
    @State private var timedOut = false
    @State private var retryNonce = 0
    @State private var transferProgress: Double?

    private var showsRetry: Bool { interrupted || timedOut }

    var body: some View {
        Group {
            if let image {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if kind == "image/gif", let jpeg {
                            AnimatedStickerImage(data: jpeg, cacheKey: id.uuidString,
                                                 animate: isVisible && scenePhase == .active && !reduceMotion)
                                .frame(width: 144, height: 144)
                        } else {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                    }
                        .onTapGesture { preview(image) }
                        .accessibilityLabel("打开照片预览")
                    Button {
                        guard let jpeg else { return }
                        Task {
                            do { try await PrivatePhotoLibrary.save(jpeg); saveStatus = "照片已保存到相册。" }
                            catch { saveStatus = "未能保存到相册，请检查照片权限。" }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.56), in: Circle())
                    }.accessibilityLabel("保存到相册").padding(8)
                }
            } else {
                VStack(spacing: 10) {
                    Label(showsRetry ? "传输暂时中断" : "正在安全传输", systemImage: "photo.badge.arrow.down")
                    if let transferProgress, transferProgress > 0 {
                        ProgressView(value: transferProgress)
                            .frame(width: 130)
                        Text("\(Int(transferProgress * 100))%")
                            .font(.caption2).monospacedDigit()
                    }
                    if showsRetry {
                        Button("重试") {
                            timedOut = false
                            retryNonce += 1
                            Task { await retry() }
                        }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 210, height: 140)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("photo-awaiting-transfer")
            }
        }
        .onScrollVisibilityChange(threshold: 0.05) { isVisible = $0 }
        .task(id: "\(scenePhase)-\(refresh?.timeIntervalSince1970 ?? 0)-\(retryNonce)") {
            // Rotation and system overlays can briefly make the scene inactive. Keep the
            // decoded photo alive so an open full-screen viewer is not torn down.
            guard scenePhase == .active else { return }
            for attempt in 0..<8 {
                jpeg = try? await load(id)
                image = jpeg.flatMap(UIImage.init(data:))
                transferProgress = await progress()
                if image != nil || attempt == 7 { break }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, scenePhase == .active else { break }
            }
            if image == nil, scenePhase == .active { timedOut = true }
        }
        .alert("照片", isPresented: Binding(get: { saveStatus != nil }, set: { if !$0 { saveStatus = nil } })) {
            Button("好") { saveStatus = nil }
        } message: { Text(saveStatus ?? "") }
    }
}

struct AnimatedStickerImage: UIViewRepresentable {
    let data: Data
    let cacheKey: String
    let animate: Bool

    final class Animation: NSObject {
        let frames: [UIImage]
        let duration: TimeInterval
        let cost: Int
        init(frames: [UIImage], duration: TimeInterval, cost: Int) {
            self.frames = frames; self.duration = duration; self.cost = cost
        }
    }
    final class Coordinator {
        var key: String?
        var generation = UUID()
        var isAnimating = false
    }
    private static let cache: NSCache<NSString, Animation> = {
        let cache = NSCache<NSString, Animation>()
        cache.countLimit = 24
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        if !animate {
            context.coordinator.generation = UUID()
            context.coordinator.isAnimating = false
            view.stopAnimating()
            if let first = view.animationImages?.first { view.image = first }
            view.animationImages = nil
            return
        }
        if context.coordinator.key == cacheKey, context.coordinator.isAnimating { return }
        if context.coordinator.key != cacheKey {
            context.coordinator.key = cacheKey
            view.stopAnimating(); view.animationImages = nil
            view.image = UIImage(data: data)
        }
        let generation = UUID(); context.coordinator.generation = generation
        if let cached = Self.cache.object(forKey: cacheKey as NSString) {
            Self.play(cached, in: view, coordinator: context.coordinator, generation: generation)
            return
        }
        let bytes = data
        Task.detached(priority: .utility) {
            guard let decoded = Self.decode(bytes) else { return }
            await MainActor.run {
                guard context.coordinator.generation == generation else { return }
                Self.cache.setObject(decoded, forKey: cacheKey as NSString, cost: decoded.cost)
                Self.play(decoded, in: view, coordinator: context.coordinator, generation: generation)
            }
        }
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.generation = UUID(); coordinator.isAnimating = false
        view.stopAnimating(); view.animationImages = nil; view.image = nil
    }
    @MainActor private static func play(_ animation: Animation, in view: UIImageView,
                                        coordinator: Coordinator, generation: UUID) {
        guard coordinator.generation == generation, !animation.frames.isEmpty else { return }
        view.animationImages = animation.frames
        view.animationDuration = animation.duration
        view.animationRepeatCount = 0
        view.image = animation.frames.first
        coordinator.isAnimating = true
        view.startAnimating()
    }
    nonisolated private static func decode(_ data: Data) -> Animation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var frames: [UIImage] = [], duration = 0.0, cost = 0
        for index in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            cost += cg.width * cg.height * 4
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        }
        guard !frames.isEmpty else { return nil }
        return Animation(frames: frames, duration: max(duration, 0.1), cost: cost)
    }
}

private struct LocalStickerBubble: View {
    let sticker: InstalledSticker
    @State private var data: Data?
    @State private var isVisible = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let data {
                if sticker.record.mediaType == "image/gif" {
                    AnimatedStickerImage(data: data, cacheKey: sticker.id,
                                         animate: isVisible && scenePhase == .active && !reduceMotion)
                } else if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 144, height: 144)
        .onScrollVisibilityChange(threshold: 0.05) { isVisible = $0 }
        .task(id: sticker.id) {
            data = try? Data(contentsOf: sticker.mediaURL, options: .mappedIfSafe)
        }
        .accessibilityLabel("表情")
    }
}

private struct PhotoPreview: Identifiable {
    let id = UUID()
    let photoIDs: [UUID]
    let selectedID: UUID
    let seedImage: UIImage
}

private struct PhotoViewer: View {
    let preview: PhotoPreview
    let load: (UUID) async throws -> Data?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID
    @State private var quarterTurns: [UUID: Int] = [:]

    init(preview: PhotoPreview, load: @escaping (UUID) async throws -> Data?) {
        self.preview = preview
        self.load = load
        _selectedID = State(initialValue: preview.selectedID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selectedID) {
                ForEach(preview.photoIDs, id: \.self) { photoID in
                    GalleryPhotoPage(
                        id: photoID,
                        seedImage: photoID == preview.selectedID ? preview.seedImage : nil,
                        quarterTurns: quarterTurns[photoID, default: 0],
                        load: load
                    )
                    .tag(photoID)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.vertical, 70)
            VStack {
                HStack {
                    Button("关闭") { dismiss() }
                    Spacer()
                    Button { quarterTurns[selectedID] = (quarterTurns[selectedID, default: 0] + 3) % 4 } label: { Image(systemName: "rotate.left") }
                        .accessibilityLabel("向左旋转")
                    Button { quarterTurns[selectedID] = (quarterTurns[selectedID, default: 0] + 1) % 4 } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel("向右旋转")
                }.font(.headline).foregroundStyle(.white).padding()
                Spacer()
                VStack(spacing: 5) {
                    if preview.photoIDs.count > 1 {
                        Text("\((preview.photoIDs.firstIndex(of: selectedID) ?? 0) + 1) / \(preview.photoIDs.count)")
                    }
                    Text(preview.photoIDs.count > 1 ? "左右滑动 · 双击或双指缩放" : "双击缩放 · 双指捏合查看")
                }
                .font(.caption).foregroundStyle(.white.opacity(0.72)).padding()
            }
        }.preferredColorScheme(.dark)
    }
}

private struct GalleryPhotoPage: View {
    let id: UUID
    let seedImage: UIImage?
    let quarterTurns: Int
    let load: (UUID) async throws -> Data?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image.rotated(quarterTurns: quarterTurns))
                    .id(quarterTurns)
            } else {
                ProgressView("加载照片…").tint(.white).foregroundStyle(.white)
            }
        }
        .task(id: id) {
            if image == nil { image = seedImage }
            if image == nil, let data = try? await load(id) { image = UIImage(data: data) }
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        let view = context.coordinator.imageView
        view.translatesAutoresizingMaskIntoConstraints = false; view.contentMode = .scaleAspectFit
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(doubleTap); context.coordinator.scroll = scroll
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) { context.coordinator.imageView.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView(); weak var scroll: UIScrollView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2.5, animated: true)
        }
    }
}

private extension UIImage {
    func rotated(quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        let swapped = turns % 2 == 1
        let size = swapped ? CGSize(width: self.size.height, height: self.size.width) : self.size
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: CGFloat(turns) * .pi / 2)
            draw(in: CGRect(x: -self.size.width / 2, y: -self.size.height / 2,
                            width: self.size.width, height: self.size.height))
        }
    }
}

private struct ChatSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
