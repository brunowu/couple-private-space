#if os(iOS)
import SwiftUI
import Domain
import Crypto
import UI
import Notification
import Transport
import UserNotifications
import CoreImage.CIFilterBuiltins
import PhotosUI
import Vision

@MainActor public final class NetworkSpaceModel: ObservableObject {
    public static let shared = NetworkSpaceModel()
    @Published var stage = "loading"
    @Published var output = ""
    @Published var error: String?
    @Published var busy = false
    @Published var online = true
    @Published var state = SharedState()
    @Published var localID = UUID()
    @Published var owner = false
    @Published var lastSync: Date?
    @Published var pending = 0
    @Published var creator = false
    @Published var verificationCode: String?
    @Published var inviteExpiry: Date?
    @Published var peerDeviceID: UUID?
    @Published var deliveries: [UUID: DeliveryState] = [:]
    @Published var reminderStatus = "愿望提醒尚未开启。"
    @Published var affection: Affection?
    @Published var capsuleDrafts: [CapsuleDraft] = []
    @Published var privateCycle: CycleEntry?
    @Published var openedCapsules: Set<UUID> = []
    @Published var capsuleReminderStatus = "胶囊到期提醒尚未开启。"
    @Published var anniversaryReminderStatus = "纪念日提醒尚未开启。"
    @Published var pushStatus = "后台通知尚未开启。"
    @Published var notificationFeedback: String?
    @Published var backupStatus = "尚未创建加密备份。"
    private var registeredPush: String?
    private var registeringPush = false
    private var client: NetworkPair?
    private var syncing = false
    private var scheduling = false
    public init() {
        #if DEBUG && targetEnvironment(simulator)
        // Disable lifecycle sync before the first await: otherwise the foreground task
        // can race the deterministic driver and report before an in-flight fetch commits.
        if ProcessInfo.processInfo.arguments.contains("--network-smoke") { online = false }
        #endif
    }
    func start() async {
        do {
            if client == nil {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("NetworkSpace")
                // v2 intentionally starts a fresh cryptographic identity after the
                // 2026-09 clean reinstall; iOS retains old Keychain items after uninstall.
                client = try NetworkPair(directory: directory, vault: KeychainVault(service: "private.couple.network.v2"))
            }
            await refresh()
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--network-smoke") {
                await smokeStep()
            }
            if ProcessInfo.processInfo.arguments.contains("--capsule-ui-test"), stage == "paired" {
                try await configureCapsuleReminders(true)
                try await save(.journal(.sealCapsule(CapsuleContent(title: "到期提醒验收", text: "到时才看得到的心里话", opensAt: Date().addingTimeInterval(20)))), objectID: UUID())
            }
            if ProcessInfo.processInfo.arguments.contains("--affection-notification-ui-test"), stage == "paired", let client {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                guard let id = try await client.latestAffectionActionID() else { throw SpaceError.missingRecord }
                let content = UNMutableNotificationContent()
                content.title = "我们"; content.body = "你收到了一份小心意"; content.categoryIdentifier = "PRIVATE_AFFECTION"
                content.userInfo = ["affection_envelope": id.uuidString]
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "affection-action-ui-test", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 12, repeats: false)))
                pushStatus = "模拟通知已安排。"
            }
            if ProcessInfo.processInfo.arguments.contains("--wish-notification-ui-test"), stage == "paired" {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                guard let wish = state.wishes.values.first(where: {
                    $0.creator != localID && $0.status == .active && $0.text.hasPrefix("周末一起吃早餐 · ")
                }) else { throw SpaceError.missingRecord }
                let content = UNMutableNotificationContent()
                content.title = "我们"; content.body = "你有一个愿望提醒"
                content.userInfo = ["destination": "wish", "object_id": wish.id.uuidString]
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wish-route-ui-test", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 12, repeats: false)))
            }
            if ProcessInfo.processInfo.arguments.contains("--message-notification-ui-test"), stage == "paired" {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                let content = UNMutableNotificationContent()
                content.title = "我们"; content.body = "你有一条新消息"
                content.userInfo = ["destination": "message"]
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "message-route-ui-test", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 12, repeats: false)))
            }
            #endif
        } catch { self.error = String(describing: error) }
    }
    func refresh() async {
        guard let client else { return }
        var status = await client.status()
        if status.stage == "awaitingPeer" {
            do { _ = try await client.activateWhenReady() }
            catch { self.error = Self.pairingError(error) }
            status = await client.status()
        }
        output = status.output; owner = status.owner; creator = status.creator
        inviteExpiry = try? await client.invitationExpiry()
        peerDeviceID = await client.peerDeviceID()
        verificationCode = try? await client.verificationCode()
        if let id = status.localID { localID = id }
        if status.stage == "paired" {
            do {
                state = try await client.state(); pending = try await client.pendingCount()
                deliveries = try await client.deliveries()
                capsuleDrafts = try await client.capsuleDrafts()
                privateCycle = try await client.privateCycle()
                openedCapsules = try await client.openedCapsules()
                stage = status.stage
            }
            catch { self.error = error.localizedDescription }
        } else if status.stage == "revoked" {
            do {
                state = try await client.retainedState(); error = nil
                if stage != "revoked" { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
                stage = status.stage
            }
            catch { self.error = error.localizedDescription }
        } else { stage = status.stage }
    }
    func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await action(); error = nil } catch {
            self.error = stage == "paired" ? error.localizedDescription : Self.pairingError(error)
        }
        await refresh()
        await reconcileReminders()
    }
    func save(_ payload: EventPayload, objectID: UUID) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.createEvent(payload, objectID: objectID)
        await refresh()
        await reconcileReminders()
        // Disk commit defines success. Network failure must not discard or duplicate a saved draft.
        Task { await self.sync() }
    }
    func savePhoto(_ jpeg: Data, width: Int, height: Int) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.createPhoto(jpeg, width: width, height: height)
        await refresh()
        Task { await self.sync() }
    }
    func saveSticker(_ data: Data, kind: String, width: Int, height: Int) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.createSticker(data, kind: kind, width: width, height: height)
        await refresh()
        Task { await self.sync() }
    }
    func saveMemoryWithPhoto(_ memory: MemoryContent, jpeg: Data,
                             width: Int, height: Int, id: UUID) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.createMemoryWithPhoto(memory, jpeg: jpeg, width: width, height: height, id: id)
        await refresh()
        Task { await self.sync() }
    }
    func photoData(_ id: UUID) async throws -> Data? {
        guard let client else { throw SpaceError.notPaired }
        return try await client.photoData(id)
    }
    func createEncryptedBackup() async throws -> SpaceBackupArtifact {
        guard let client else { throw SpaceError.notPaired }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoupleBackups", isDirectory: true)
        let artifact = try await client.createEncryptedBackup(outputDirectory: directory)
        backupStatus = "备份已在本机完成校验。恢复密钥需要与备份文件分开保存。"
        return artifact
    }

    func verifyEncryptedBackup(fileURL: URL, recoveryKey: String) async throws -> SpaceBackupPreview {
        guard let client else { throw SpaceError.notPaired }
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        let preview = try await client.verifyEncryptedBackup(fileURL: fileURL, recoveryKey: recoveryKey)
        backupStatus = "备份完整且密钥正确。校验过程没有修改当前空间。"
        return preview
    }

    /// Restores only while this installation is still an unpaired, empty shell.
    func restoreEncryptedBackup(fileURL: URL, recoveryKey: String) async throws -> SpaceBackupPreview {
        guard stage == "new", let status = await client?.status(), status.stage == "new" else {
            throw SpaceBackupError.destinationNotEmpty
        }
        busy = true; defer { busy = false }
        let preview = try await verifyEncryptedBackup(fileURL: fileURL, recoveryKey: recoveryKey)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("NetworkSpace")
        let vault = KeychainVault(service: "private.couple.network.v2")
        let secretNames = ["network.database", "network.auth", "identity.\(preview.localDeviceID.uuidString)"]

        client = nil
        try? FileManager.default.removeItem(at: directory)
        for name in secretNames { try vault.remove(name) }
        do {
            let access = fileURL.startAccessingSecurityScopedResource()
            defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
            let restored = try SpaceBackupService.restore(fileURL: fileURL, recoveryKey: recoveryKey,
                                                           directory: directory, vault: vault)
            client = try NetworkPair(directory: directory, vault: vault)
            await refresh()
            guard stage == "paired" else { throw SpaceBackupError.damagedPayload }
            backupStatus = "已从加密备份恢复这台设备的配对、密钥和全部内容。"
            await updatePushRegistration()
            Task { await self.sync() }
            return restored
        } catch {
            // Recovery failure may not leave a partial identity behind. Recreate a clean shell.
            client = nil
            try? FileManager.default.removeItem(at: directory)
            for name in secretNames { try? vault.remove(name) }
            client = try? NetworkPair(directory: directory, vault: vault)
            await refresh()
            throw error
        }
    }
    func updateProfile(name: String, avatar: (jpeg: Data, width: Int, height: Int)?,
                       retainedAvatarID: UUID?) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.updateProfile(name: name, avatar: avatar, retainedAvatarID: retainedAvatarID)
        await refresh()
        Task { await self.sync() }
    }
    func sendAffection(_ kind: AffectionKind) async throws -> Bool {
        guard let client else { throw SpaceError.notPaired }
        let sent = try await client.sendAffection(kind)
        Task { await self.sync() }
        return sent
    }
    func configurePush(affection: Bool, messages: Bool, wishes: Bool) async throws {
        UserDefaults.standard.set(affection, forKey: "affection-push-enabled")
        UserDefaults.standard.set(messages, forKey: "message-push-enabled")
        UserDefaults.standard.set(wishes, forKey: "wish-push-enabled")
        registeredPush = nil
        if affection || messages || wishes {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { pushStatus = "系统通知未授权，可在系统设置中开启。"; return }
            UIApplication.shared.registerForRemoteNotifications()
        }
        await updatePushRegistration()
    }
    func updatePushRegistration() async {
        guard stage == "paired", let client, !registeringPush else { return }
        registeringPush = true; defer { registeringPush = false }
        let affection = UserDefaults.standard.object(forKey: "affection-push-enabled") as? Bool ?? true
        let messages = UserDefaults.standard.object(forKey: "message-push-enabled") as? Bool ?? true
        let wishes = UserDefaults.standard.object(forKey: "wish-push-enabled") as? Bool ?? true
        let enabled = affection || messages || wishes
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized: Bool
        if enabled && settings.authorizationStatus == .notDetermined {
            authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true
        } else {
            authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
        let router = SpaceNotificationDelegate.shared
        if enabled && authorized && router.pushToken == nil {
            UIApplication.shared.registerForRemoteNotifications()
            pushStatus = router.pushRegistrationFailed ? "设备推送注册尚未成功。模拟通知仍可用于本地验收。" : "正在向系统注册推送…"
            return
        }
        let token = enabled && authorized ? router.pushToken : nil
        let fingerprint = "\(token ?? "disabled"):\(affection):\(messages):\(wishes)"
        guard registeredPush != fingerprint else { return }
        do {
            try await client.registerPush(token: token, environment: Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? "sandbox", affection: affection, messages: messages, wishes: wishes)
            registeredPush = fingerprint
            pushStatus = token == nil ? "后台通知已关闭。" : "设备通知已登记。真实投递仍需中继配置 Apple 推送凭据，并经过真机验收。"
        } catch { pushStatus = "推送设置尚未同步，恢复连接后重试。" }
    }
    func handleAffectionNotification(_ action: AffectionNotificationAction) async {
        guard let client else { return }
        // Let an existing foreground fetch finish before resolving a notification's envelope.
        while syncing { try? await Task.sleep(for: .milliseconds(100)); if Task.isCancelled { return } }
        await sync()
        if action.respond {
            do {
                let sent = try await client.respondToAffection(action.envelopeID)
                pushStatus = sent ? "已回应这份心意。" : "刚刚已经回应过了。"
                notificationFeedback = pushStatus
                Task {
                    let shown = notificationFeedback
                    try? await Task.sleep(for: .seconds(5))
                    if notificationFeedback == shown { notificationFeedback = nil }
                }
                await sync()
            } catch { self.error = "这份心意已过期或尚未验证，未发送回应。请同步后重试。" }
        }
    }
    public func backgroundRefresh() async -> Bool {
        if client == nil { await start() }
        guard let client, stage == "paired" else { return false }
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { try await client.synchronize(); return true } catch { return false } }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
            let result = await group.next() ?? false; group.cancelAll(); return result
        }
        if result { await refresh(); await reconcileReminders() }
        return result
    }
    func saveCapsuleDraft(_ value: CapsuleDraft) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.saveCapsuleDraft(value)
        capsuleDrafts = try await client.capsuleDrafts()
    }
    func sealCapsuleDraft(_ value: CapsuleDraft) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.sealCapsuleDraft(value)
        await refresh()
        await reconcileReminders()
        Task { await self.sync() }
    }
    func discardCapsuleDraft(_ id: UUID) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.discardCapsuleDraft(id)
        capsuleDrafts = try await client.capsuleDrafts()
    }
    func prepareCapsuleDraft(_ value: CapsuleDraft) async throws -> CapsuleDraft {
        guard let client else { throw SpaceError.notPaired }
        let next = try await client.prepareCapsuleDraft(value)
        capsuleDrafts = try await client.capsuleDrafts()
        return next
    }
    func openCapsule(_ id: UUID) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.openCapsule(id)
        openedCapsules = try await client.openedCapsules()
        await reconcileCapsuleReminders()
    }
    func configureCapsuleReminders(_ enabled: Bool) async throws {
        UserDefaults.standard.set(enabled, forKey: "capsule-reminders-enabled")
        if enabled { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        await reconcileCapsuleReminders()
    }
    func configureAnniversaryReminders(enabled: Bool, daysBefore: Int) async throws {
        guard [0, 1, 3, 7].contains(daysBefore) else { throw SpaceError.invalidInput }
        UserDefaults.standard.set(enabled, forKey: "anniversary-reminders-enabled")
        UserDefaults.standard.set(daysBefore, forKey: "anniversary-reminder-days")
        if enabled { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        await reconcileAnniversaryReminders()
        await reconcileCapsuleReminders()
    }
    private func reconcileAnniversaryReminders() async {
        let enabled = UserDefaults.standard.bool(forKey: "anniversary-reminders-enabled")
        let days = UserDefaults.standard.object(forKey: "anniversary-reminder-days") as? Int ?? 3
        do {
            let plans = AnniversaryReminder.plans(records: state.journal.anniversaries, daysBefore: days)
            let count = try await AnniversaryReminderScheduler().reconcile(plans, enabled: enabled)
            anniversaryReminderStatus = enabled ? "已安排 \(count) 个纪念日提醒，锁屏不显示名称。" : "纪念日提醒已关闭。"
        } catch { anniversaryReminderStatus = "纪念日提醒尚未安排，请检查系统通知权限。" }
    }
    func openWishReminder(_ id: UUID) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.openWishReminder(id)
        await reconcileReminders()
    }
    private func reconcileCapsuleReminders() async {
        let enabled = UserDefaults.standard.bool(forKey: "capsule-reminders-enabled")
        do {
            let count = try await CapsuleReminderScheduler().reconcile(CapsuleReminder.eligible(journal: state.journal, opened: openedCapsules), enabled: enabled)
            capsuleReminderStatus = enabled ? "已安排 \(count) 个到期提醒。通知不会显示胶囊标题或内容。" : "胶囊到期提醒已关闭。"
        } catch { capsuleReminderStatus = "暂未安排提醒，请检查系统通知权限。胶囊仍可到期后在 App 中打开。" }
    }
    private func showAffections() async {
        guard stage == "paired", UIApplication.shared.applicationState == .active, let client else { return }
        do {
            // Coalesce a burst to the latest interaction instead of replaying a queue of effects.
            guard let latest = try await client.takeAffections().last,
                  UIApplication.shared.applicationState == .active else { return }
            affection = latest
            Task {
                try? await Task.sleep(for: .seconds(6))
                if affection?.id == latest.id { affection = nil }
            }
        } catch { self.error = "小心意暂未读取成功，请稍后重试。" }
    }
    private var quietHours: QuietHours {
        QuietHours(enabled: UserDefaults.standard.bool(forKey: "wish-quiet-enabled"),
                   startHour: UserDefaults.standard.object(forKey: "wish-quiet-start") as? Int ?? 22,
                   endHour: UserDefaults.standard.object(forKey: "wish-quiet-end") as? Int ?? 8)
    }
    func configureReminders(enabled: Bool, days: Int, quiet: QuietHours) async throws {
        try quiet.validate()
        guard (1...30).contains(days) else { throw SpaceError.invalidInput }
        let oldDays = UserDefaults.standard.integer(forKey: "wish-reminder-days")
        if days != oldDays || quiet != quietHours { try await client?.resetReminderWindow() }
        UserDefaults.standard.set(quiet.enabled, forKey: "wish-quiet-enabled")
        UserDefaults.standard.set(quiet.startHour, forKey: "wish-quiet-start")
        UserDefaults.standard.set(quiet.endHour, forKey: "wish-quiet-end")
        UserDefaults.standard.set(enabled, forKey: "wish-reminders-enabled")
        UserDefaults.standard.set(days, forKey: "wish-reminder-days")
        if enabled {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if !granted { reminderStatus = "系统通知未授权。你仍然可以正常查看愿望，可前往系统设置允许通知。" }
        }
        await reconcileReminders()
    }
    private func reconcileReminders() async {
        guard let client, stage == "paired", !scheduling else { return }
        scheduling = true; defer { scheduling = false }
        // Trim legacy capsule schedules before allocating the other notification categories.
        await reconcileCapsuleReminders()
        do {
            let enabled = UserDefaults.standard.bool(forKey: "wish-reminders-enabled")
            let zone = TimeZone.autoupdatingCurrent.identifier
            if quietHours.enabled && UserDefaults.standard.string(forKey: "wish-reminder-time-zone") != zone {
                try await client.resetReminderWindow()
            }
            UserDefaults.standard.set(zone, forKey: "wish-reminder-time-zone")
            let days = UserDefaults.standard.integer(forKey: "wish-reminder-days")
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            let scheduler = SystemReminderScheduler()
            var count = 0
            let intents = try await client.reminderIntents().sorted { ($0.fireAt ?? $0.receivedAt) < ($1.fireAt ?? $1.receivedAt) }
            for var intent in intents {
                if !enabled || intent.state == .cancelled || intent.state == .opened {
                    await scheduler.cancel(requestID: intent.requestID); continue
                }
                guard authorized else { continue }
                if intent.fireAt == nil { intent = try await client.planReminder(wishID: intent.wishID, days: (1...30).contains(days) ? days : 7, quiet: quietHours) }
                // Past reminders never become a new immediate alert on relaunch.
                if let date = intent.fireAt, date > Date() {
                    if count < 30 { try await scheduler.upsert(intent); count += 1 }
                    else { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [intent.requestID.uuidString]) }
                }
            }
            reminderStatus = !enabled ? "愿望提醒已关闭。" : !authorized ? "系统通知未授权，请在系统设置中允许通知。" : "已安排 \(count) 个提醒。时间仅保存在你的设备；修改窗口会重新安排尚未到期的提醒。"
        } catch { reminderStatus = "提醒暂未安排成功，将在下次同步重试。" }
        await reconcileAnniversaryReminders()
        await reconcileCapsuleReminders()
    }
    func create(endpoint: String, token: String, owner: Bool) async {
        await perform {
            guard let client, let url = URL(string: endpoint) else { return }
            try await client.create(endpoint: url, bootstrap: token, ownsCycle: owner)
        }
    }
    func previewVerification(_ text: String) async -> String? {
        guard let client else { return nil }
        do { let code = try await client.verificationCode(response: text); error = nil; return code }
        catch { self.error = Self.pairingError(error); return nil }
    }
    func importPayload(_ text: String, codeConfirmed: Bool = false) async {
        await perform {
            guard let client else { return }
            if ["invited", "responded", "confirming"].contains(stage) && !codeConfirmed { throw SpaceError.unauthorized }
            switch stage {
            case "new", "joining": try await client.join(text)
            case "invited": try await client.acceptResponse(text)
            case "responded": try await client.acceptFinal(text)
            case "confirming":
                if creator { try await client.acceptResponse(text) }
                else { try await client.acceptFinal(text) }
            default: throw SpaceError.conflict
            }
        }
    }
    private static func pairingError(_ error: Error) -> String {
        if let error = error as? SpaceError {
            switch error {
            case .expired: return "邀请已过期。请在第一台更新邀请，再重新导入。"
            case .invalidInput, .invalidEnvelope: return "配对资料无法识别。请重新复制完整内容，或换一张清晰的二维码图片。"
            case .unauthorized: return "身份或核对码不匹配。请停止配对，向伴侣当面确认资料。"
            case .conflict: return "这份资料与当前配对进度不一致。请使用此空间最新的邀请与回应。"
            default: return error.localizedDescription
            }
        }
        if let relay = error as? RelayHTTPError {
            switch relay.status {
            case 401, 403: return "服务口令不正确或设备身份未获授权。请核对口令与当前邀请。"
            case 404, 410: return "邀请已失效。请在第一台更新邀请，再重新导入。"
            case 409: return "中继已有另一组配对进度。请确认两台设备连接的是同一个空间。"
            default: return "中继暂时拒绝了配对请求（HTTP \(relay.status)），请检查连接后重试。"
            }
        }
        if error is URLError { return "暂时无法连接中继。检查两台设备的网络和服务地址后重试；现有配对进度已保留。" }
        if error is DecodingError { return "配对资料格式不完整或版本不兼容，请重新导入。" }
        return error.localizedDescription
    }
    func sync() async {
        if stage == "awaitingPeer" { await refresh() }
        guard stage == "paired", online, !busy, !syncing else { return }
        syncing = true; defer { syncing = false }
        do { try await client?.synchronize(); lastSync = Date(); error = nil }
        catch { self.error = error.localizedDescription }
        await refresh()
        await reconcileReminders()
        await showAffections()
        await updatePushRegistration()
    }
    func revokePairing() async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.revokePairing()
        await refresh()
        registeredPush = nil
    }
    func event(_ payload: EventPayload, id: UUID = UUID()) async {
        do { try await client?.createEvent(payload, objectID: id); error = nil }
        catch { self.error = error.localizedDescription }
        await refresh()
        await sync()
    }
    func cycle(_ entry: CycleEntry) async throws {
        guard let client else { throw SpaceError.notPaired }
        try await client.saveCycle(entry)
        await refresh()
        Task { await sync() }
    }
    #if DEBUG && targetEnvironment(simulator)
    /// Explicit simulator-only test driver. Exports public pairing payloads and counts, never keys or message contents.
    private func smokeStep() async {
        let args = ProcessInfo.processInfo.arguments
        func arg(_ flag: String) -> String {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return "" }; return args[i + 1]
        }
        let action = arg("--step")
        online = false // The driver controls every network exchange deterministically.
        var receivedAffections: [Affection] = []
        var coalescedAffection = false
        do {
            guard let client else { throw SpaceError.missingRecord }
            switch action {
            case "create": try await client.create(endpoint: URL(string: arg("--endpoint"))!, bootstrap: "local-simulator-only", ownsCycle: false)
            case "join": try await client.join(arg("--payload"))
            case "respond": try await client.acceptResponse(arg("--payload"))
            case "final": try await client.acceptFinal(arg("--payload"))
            case "message": try await client.createEvent(.message(text: "想和你一起散步 · " + arg("--run-id")))
            case "wish": try await client.createEvent(.wishCreated(text: "周末一起吃早餐 · " + arg("--run-id")))
            case "affection":
                _ = try await client.sendAffection(.hug)
                coalescedAffection = try await !client.sendAffection(.hug)
            case "take-affection": receivedAffections = try await client.takeAffections()
            case "duet":
                guard let id = UUID(uuidString: arg("--run-id")) else { throw SpaceError.invalidInput }
                try await client.createEvent(.journal(.sealCapsule(CapsuleContent(title: "两份心里话", text: "我的一份", opensAt: Date().addingTimeInterval(86_400), partnerSlotID: UUID()))), objectID: id)
            case "join-duet":
                guard let id = UUID(uuidString: arg("--payload")), let root = try await client.state().journal.capsules[id], let slot = root.value.partnerSlotID else { throw SpaceError.missingRecord }
                try await client.createEvent(.journal(.sealCapsule(CapsuleContent(title: root.value.title, text: "伴侣的一份", opensAt: root.value.opensAt, companionOf: id))), objectID: slot)
            case "journal":
                guard let id = UUID(uuidString: arg("--run-id")) else { throw SpaceError.invalidInput }
                try await client.createEvent(.journal(.checklist(ChecklistContent(text: "一起做早餐", category: .eat))), objectID: id)
                try await client.createEvent(.journal(.memory(MemoryContent(title: "平凡的一天", text: "一起吃了早餐", date: Date()))), objectID: id)
                try await client.createEvent(.journal(.sealCapsule(CapsuleContent(title: "写给明天", text: "记得拥抱", opensAt: Date().addingTimeInterval(86_400)))), objectID: id)
            case "complete-list":
                guard let id = UUID(uuidString: arg("--payload")), var value = try await client.state().journal.checklist[id]?.value else { throw SpaceError.missingRecord }
                value.completed = true; try await client.createEvent(.journal(.checklist(value)), objectID: id)
            case "cancel-capsule":
                guard let id = UUID(uuidString: arg("--payload")) else { throw SpaceError.invalidInput }
                try await client.createEvent(.journal(.cancelCapsule), objectID: id)
            case "sync": try await client.synchronize()
            case "anniversary":
                guard let id = UUID(uuidString: arg("--run-id")) else { throw SpaceError.invalidInput }
                try await client.createEvent(.journal(.anniversary(AnniversaryContent(title: "HTTP 纪念日测试", date: "2024-02-29"))), objectID: id)
            case "edit-anniversary", "delete-anniversary":
                guard let id = UUID(uuidString: arg("--payload")), var value = try await client.state().journal.anniversaries[id]?.value else { throw SpaceError.missingRecord }
                value.date = "2024-03-01"; value.deleted = action == "delete-anniversary"
                try await client.createEvent(.journal(.anniversary(value)), objectID: id)
            case "cycle-estimate", "cycle-revoke":
                let status = await client.status()
                guard status.owner, let id = status.localID else { throw SpaceError.unauthorized }
                let current = try await client.state()
                try await client.createEvent(.cycle(SharedCycleProjection(owner: id, generation: (current.cycle?.generation ?? 0) + 1,
                    revision: 1, startDate: nil, revoked: action == "cycle-revoke",
                    estimatedNextDate: action == "cycle-estimate" ? "2026-10-09" : nil)))
            case "clean-cycle-fixture":
                guard let id = (await client.status()).localID, id == localID,
                      var entry = try await client.privateCycle() else { break }
                let note = entry.record.note ?? ""
                if note.range(of: "^(private-[0-9a-f]{6})+$", options: .regularExpression) != nil {
                    entry.record.note = nil
                }
                // Restore the owner's saved share switches after the HTTP projection test,
                // even when a previous run has already removed its synthetic note.
                try await client.saveCycle(entry)
            case "cycle":
                let status = await client.status()
                guard status.owner, let id = status.localID else { throw SpaceError.unauthorized }
                let current = try await client.state()
                try await client.createEvent(.cycle(SharedCycleProjection(owner: id, generation: (current.cycle?.generation ?? 0) + 1,
                    revision: 1, startDate: "2026-09-11", revoked: false)))
            case "status": break
            default: throw SpaceError.invalidInput
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
        let report: [String: Any] = ["runID": arg("--run-id"), "step": action, "stage": stage, "output": output,
            "localID": localID.uuidString, "messages": state.messages.count, "wishes": state.wishes.count,
            "checklists": state.journal.checklist.count, "memories": state.journal.memories.count,
            "capsules": state.journal.capsules.count,
            "anniversaries": state.journal.anniversaries.values.filter { !$0.value.deleted }.count,
            "editedAnniversaries": state.journal.anniversaries.values.filter { !$0.value.deleted && $0.value.date == "2024-03-01" }.count,
            "hasSharedCycleDate": state.cycle?.startDate != nil,
            "hasCycleEstimate": state.cycle?.estimatedNextDate != nil, "cycleRevoked": state.cycle?.revoked ?? true,
            "hasPrivateCycle": privateCycle != nil,
            "completedDuets": state.journal.capsules.values.filter { state.journal.contributions(to: $0.id).count == 2 }.count,
            "completedLists": state.journal.checklist.values.filter { $0.value.completed }.count,
            "cancelledCapsules": state.journal.capsules.values.filter { state.journal.isCancelled($0) }.count,
            "affectionCount": receivedAffections.count, "affectionCoalesced": coalescedAffection,
            "pending": pending, "error": error ?? ""]
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("network-smoke.json"), options: .atomic)
        }
    }
    #endif
}

public struct NetworkSpaceView: View {
    @ObservedObject private var notificationRouter = SpaceNotificationDelegate.shared
    @StateObject private var model = NetworkSpaceModel.shared
    @StateObject private var privacyLock = AppPrivacyLock()
    @Environment(\.scenePhase) private var scenePhase
    @State private var endpoint = "http://127.0.0.1:8787"
    @State private var bootstrap = ""
    @State private var ownsCycle = false
    @State private var input = ""
    @State private var showFinal = false
    @State private var createHere = true
    @State private var previewCode: String?
    @State private var codeConfirmed = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingRestoreImporter = false
    @State private var showingRestoreSheet = false
    @State private var restoreURL: URL?
    @State private var restoreKey = ""
    @State private var restorePreview: SpaceBackupPreview?
    @State private var restoreError: String?
    public init() {}
    public var body: some View {
        VStack(spacing: 0) {
            if model.stage == "paired" {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--developer-tools") {
                HStack {
                    Text("开发工具").font(.caption)
                    Spacer()
                    if model.creator { Button("确认码") { showFinal = true } }
                    Button(model.online ? "模拟离线" : "恢复连接") { model.online.toggle(); Task { await model.sync() } }
                    Button { Task { await model.sync() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("同步")
                }.font(.caption).padding(12)
                }
                #endif
                ProductSpaceView(state: model.state, localID: model.localID, peerDeviceID: model.peerDeviceID,
                    pairingCode: model.verificationCode, showPairingFinal: model.creator ? { showFinal = true } : nil,
                    isCycleOwner: model.owner,
                    deliveries: model.deliveries, reminderStatus: model.reminderStatus,
                    syncStatus: !model.online ? "离线 · 内容保存在本机" : model.error != nil ? "暂未连接 · 等待重试" : model.lastSync == nil ? "等待同步" : "已连接 · 待回执 \(model.pending)",
                    photoRefresh: model.lastSync,
                    save: { try await model.save($0, objectID: $1) }, privateCycle: model.privateCycle, cycle: model.cycle,
                    savePhoto: model.savePhoto, saveSticker: model.saveSticker,
                    saveMemoryWithPhoto: model.saveMemoryWithPhoto,
                    loadPhoto: model.photoData,
                    updateProfile: model.updateProfile,
                    configureReminders: { try await model.configureReminders(enabled: $0, days: $1, quiet: $2) }, retry: model.sync,
                    affection: model.affection, sendAffection: model.sendAffection,
                    capsuleDrafts: model.capsuleDrafts, openedCapsules: model.openedCapsules,
                    saveCapsuleDraft: model.saveCapsuleDraft, sealCapsuleDraft: model.sealCapsuleDraft,
                    discardCapsuleDraft: model.discardCapsuleDraft,
                    openCapsule: model.openCapsule,
                    capsuleReminderStatus: model.capsuleReminderStatus, configureCapsuleReminders: model.configureCapsuleReminders,
                    anniversaryReminderStatus: model.anniversaryReminderStatus,
                    configureAnniversaryReminders: { try await model.configureAnniversaryReminders(enabled: $0, daysBefore: $1) },
                    notificationDestination: notificationRouter.destination, consumeNotification: { notificationRouter.destination = nil },
                    openWishReminder: model.openWishReminder, prepareCapsuleDraft: model.prepareCapsuleDraft,
                    pushStatus: model.pushStatus, configurePush: { try await model.configurePush(affection: $0, messages: $1, wishes: $2) },
                    revokePairing: model.revokePairing,
                    appLockEnabled: privacyLock.enabled, configureAppLock: privacyLock.setEnabled,
                    backupStatus: model.backupStatus,
                    createEncryptedBackup: model.createEncryptedBackup,
                    verifyEncryptedBackup: model.verifyEncryptedBackup)
            } else if model.stage == "revoked" {
                NavigationStack {
                    List {
                        Section {
                            Label("配对已解除", systemImage: "lock.shield")
                                .font(.title3.weight(.semibold))
                            Text("这台设备不再与伴侣同步，也不能用旧身份继续发送。可能是你或伴侣解除了配对。")
                            Text("本机已经收到的内容仍在加密数据库中；无法远程删除伴侣设备已经保存的副本。")
                                .foregroundStyle(.secondary)
                        }
                        Section("本机保留的对话") {
                            ForEach(model.state.messages.values.sorted { $0.version < $1.version }, id: \.id) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.author == model.localID ? "我" : "伴侣")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(message.text).textSelection(.enabled)
                                }
                            }
                        }
                        Section("本机保留的愿望") {
                            ForEach(model.state.wishes.values.sorted { $0.text < $1.text }, id: \.id) { wish in
                                Text(wish.text).textSelection(.enabled)
                            }
                        }
                        Section("本机保留的回忆") {
                            ForEach(model.state.journal.memories.values.filter { !$0.value.deleted }.sorted { $0.value.date < $1.value.date }, id: \.id) { memory in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(memory.value.title).font(.headline)
                                    Text(memory.value.text).textSelection(.enabled)
                                }
                            }
                        }
                    }.navigationTitle("本机留存")
                }
            } else {
                NavigationStack {
                    Form {
                        Section {
                            Label("只邀请你信任的那个人", systemImage: "lock.shield")
                                .font(.headline)
                            Text("两台设备会交换公开身份资料。请和伴侣当面比较同一组核对码，一致后再确认。资料和进度会留在各自设备上。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if model.stage == "new" {
                            Section("从这里开始") {
                                Picker("这台设备", selection: $createHere) {
                                    Text("创建空间").tag(true)
                                    Text("加入空间").tag(false)
                                }.pickerStyle(.segmented)
                                Button { showingRestoreImporter = true } label: {
                                    Label("从完整加密备份恢复", systemImage: "arrow.counterclockwise.circle")
                                }
                                Text("仅适用于还没有建立配对的空白安装；不会覆盖已有空间。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if model.stage == "creating" || (model.stage == "new" && createHere) {
                            Section("第一台 · 创建邀请") {
                                TextField("中继地址", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                                SecureField("本地服务启动口令", text: $bootstrap).accessibilityIdentifier("bootstrap-token")
                                Toggle("由我记录周期", isOn: $ownsCycle)
                                Button("创建空间") { Task { await model.create(endpoint: endpoint, token: bootstrap, owner: ownsCycle) } }
                                    .disabled(bootstrap.isEmpty || model.busy).accessibilityIdentifier("pair-create")
                                Text("周期由记录者本人决定分享范围。创建后将邀请交给伴侣，邀请只在 10 分钟内有效。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if !model.output.isEmpty {
                            Section(outputTitle) { payload(model.output) }
                        }
                        if model.stage == "invited" {
                            Section("邀请有效期") {
                                if let expiry = model.inviteExpiry {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        if context.date >= expiry {
                                            Text("邀请已过期，请更新后再交给伴侣")
                                                .foregroundStyle(.red).accessibilityIdentifier("pair-expiry")
                                        } else {
                                            LabeledContent("剩余时间") {
                                                Text(expiry, style: .timer).monospacedDigit().accessibilityIdentifier("pair-expiry")
                                            }
                                        }
                                    }
                                }
                                SecureField("更新时输入本地服务启动口令", text: $bootstrap)
                                    .accessibilityIdentifier("pair-renew-token")
                                Button("更新邀请（对方尚未加入时）") { Task { await model.create(endpoint: endpoint, token: bootstrap, owner: ownsCycle) } }
                                    .disabled(bootstrap.isEmpty || model.busy).accessibilityIdentifier("pair-renew")
                                Text("若伴侣已经加入，请继续导入对方的回应；不要更新邀请。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if model.stage == "awaitingPeer" {
                            Section("等待伴侣完成确认") {
                                if let code = model.verificationCode { codeDisplay(code) }
                                Text("请把上面的最终确认交给第二台。只有双方都完成确认，空间才会开放。此页会自动检查进度。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button("现在检查配对状态") { Task { await model.refresh() } }
                                    .accessibilityIdentifier("pair-check-status")
                            }
                        }
                        if shouldShowImport {
                            Section(importTitle) {
                                if model.stage == "new" || model.stage == "joining" {
                                    Text("从第一台复制邀请，或把二维码图片存入照片后在这里选择。")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                if input.isEmpty {
                                    TextEditor(text: $input).frame(height: 110).accessibilityIdentifier("pair-input")
                                } else {
                                    HStack {
                                        Label("配对资料已填入", systemImage: "checkmark.circle.fill")
                                        Spacer()
                                        Button("重新填写") { input = ""; previewCode = nil; codeConfirmed = false }
                                    }
                                }
                                PasteButton(payloadType: String.self) { values in input = values.first ?? "" }
                                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                    Label("从照片导入二维码", systemImage: "qrcode.viewfinder")
                                }.accessibilityIdentifier("pair-photo-import")
                                if model.stage == "invited" && previewCode == nil {
                                    Button("查看双方核对码") { Task { previewCode = await model.previewVerification(input) } }
                                        .disabled(input.isEmpty || model.busy)
                                }
                                if model.stage == "invited", let previewCode {
                                    verification(previewCode)
                                } else if ["responded", "confirming"].contains(model.stage), let code = model.verificationCode {
                                    verification(code)
                                }
                                Button(importButtonTitle) {
                                    Task {
                                        let previousStage = model.stage
                                        await model.importPayload(input, codeConfirmed: requiresCode && codeConfirmed)
                                        if model.stage != previousStage { input = ""; previewCode = nil; codeConfirmed = false }
                                    }
                                }
                                .disabled(input.isEmpty || model.busy || (requiresCode && (!codeConfirmed || (model.stage == "invited" && previewCode == nil))))
                                .accessibilityIdentifier("pair-import")
                            }
                        }
                        if model.busy { ProgressView("正在验证…") }
                    }.navigationTitle("建立两个人的空间")
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(8).accessibilityIdentifier("network-error") }
        }
        .accessibilityHidden(scenePhase != .active || (privacyLock.enabled && !privacyLock.unlocked))
        .sheet(isPresented: $showFinal) {
            NavigationStack { Form {
                Text("第一台已完成加密确认。请把下面的最终确认交给第二台，待对方导入后即可同步。")
                if let code = model.verificationCode { codeDisplay(code) }
                payload(model.output)
            }.navigationTitle("最后一步 · 交给伴侣").toolbar { Button("完成") { showFinal = false } } }
        }
        .fileImporter(isPresented: $showingRestoreImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                restoreURL = url; restoreKey = ""; restorePreview = nil; restoreError = nil
                showingRestoreSheet = true
            case .failure(let error): restoreError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingRestoreSheet) {
            NavigationStack {
                Form {
                    Section("恢复密钥") {
                        SecureField("CPS1-…", text: $restoreKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if let preview = restorePreview {
                        Section("已验证的备份") {
                            Text(preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("消息", value: "\(preview.messageCount)")
                            LabeledContent("媒体", value: "\(preview.photoCount)")
                            LabeledContent("愿望", value: "\(preview.wishCount)")
                            Button("确认恢复这个空间") { restoreSelectedBackup() }
                                .disabled(model.busy)
                            Text("每台手机应恢复它自己创建的备份。恢复后不要再同时使用同一设备身份的旧副本。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            Button("检查备份") { verifyRestoreSelection() }
                                .disabled(restoreKey.isEmpty || model.busy)
                            Text("检查只读取并验证备份。确认恢复后，这台空白设备将恢复原有配对身份。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let restoreError { Text(restoreError).foregroundStyle(.red) }
                    if model.busy { ProgressView("正在验证…") }
                }
                .navigationTitle("恢复加密备份")
                .toolbar { Button("取消") { showingRestoreSheet = false } }
                .onChange(of: restoreKey) { _, _ in restorePreview = nil; restoreError = nil }
            }
        }
        .onChange(of: model.stage) { _, stage in if stage == "awaitingPeer" && model.creator { showFinal = true } }
        .task { await model.start() }
        .overlay(alignment: .bottom) {
            if let feedback = model.notificationFeedback {
                Text(feedback).font(.subheadline).padding(14).background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 90).accessibilityIdentifier("notification-response-feedback")
            }
        }
        .task(id: "\(model.stage)-\(notificationRouter.affectionAction?.id.uuidString ?? "")") {
            guard model.stage == "paired", let action = notificationRouter.affectionAction else { return }
            await model.handleAffectionNotification(action)
            if notificationRouter.affectionAction?.id == action.id { notificationRouter.affectionAction = nil }
        }
        .onChange(of: notificationRouter.pushToken) { _, _ in Task { await model.updatePushRegistration() } }
        .onChange(of: input) { _, _ in previewCode = nil; codeConfirmed = false }
        .onChange(of: selectedPhoto) { _, photo in if let photo { Task { await importPhoto(photo) } } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.sync()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .task { await privacyLock.becameActive() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await privacyLock.becameActive() } }
            else { privacyLock.becameInactive() }
        }
        .overlay {
            if scenePhase != .active || (privacyLock.enabled && !privacyLock.unlocked) {
                ZStack {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.secondary)
                        Text("我们").font(.title2.weight(.semibold))
                        if scenePhase == .active && privacyLock.enabled {
                            Text("这段空间已锁定").foregroundStyle(.secondary)
                            Button("解锁") { Task { await privacyLock.unlock() } }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("app-lock-unlock")
                            if let error = privacyLock.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }.accessibilityIdentifier("privacy-shield")
            }
        }
    }
    private func verifyRestoreSelection() {
        guard let restoreURL else { return }
        restorePreview = nil; restoreError = nil
        Task {
            do { restorePreview = try await model.verifyEncryptedBackup(fileURL: restoreURL, recoveryKey: restoreKey) }
            catch { restoreError = "备份文件、恢复密钥或完整性校验不通过。" }
        }
    }
    private func restoreSelectedBackup() {
        guard let restoreURL, restorePreview != nil else { return }
        restoreError = nil
        Task {
            do {
                _ = try await model.restoreEncryptedBackup(fileURL: restoreURL, recoveryKey: restoreKey)
                showingRestoreSheet = false
            } catch SpaceBackupError.destinationNotEmpty {
                restoreError = "只能恢复到还没有配对的空白安装。"
            } catch {
                restorePreview = nil
                restoreError = "恢复未完成；这台设备仍保持空白状态。"
            }
        }
    }
    private var importTitle: String {
        switch model.stage {
        case "invited": "导入第二台的回应"
        case "responded": "导入第一台的最终确认"
        case "confirming": "重试确认（可粘贴原载荷）"
        default: "第二台 · 导入邀请"
        }
    }
    private var outputTitle: String {
        switch model.stage {
        case "invited": "第一台 · 把邀请交给伴侣"
        case "responded": "第二台 · 把回应交回第一台"
        default: "第一台 · 最终确认"
        }
    }
    private var shouldShowImport: Bool {
        if model.stage == "new" { return !createHere }
        return ["joining", "invited", "responded", "confirming"].contains(model.stage)
    }
    private var requiresCode: Bool { ["invited", "responded", "confirming"].contains(model.stage) }
    private var importButtonTitle: String {
        switch model.stage {
        case "invited": "核对一致，确认这台设备"
        case "responded": "核对一致，完成配对"
        case "confirming": "核对一致，重试连接"
        default: "导入邀请并生成回应"
        }
    }
    private func verification(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当面核对身份").font(.headline)
            codeDisplay(code)
            Text("请让伴侣打开另一台设备上的配对页，逐组比较。任何一组不同，都不要继续，也不要通过聊天发送核对码。")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("我已与伴侣确认完全一致", isOn: $codeConfirmed)
                .accessibilityIdentifier("pair-code-confirmed")
        }
    }
    private func codeDisplay(_ code: String) -> some View {
        Text(code).font(.title3.monospaced().weight(.semibold))
            .minimumScaleFactor(0.7).lineLimit(1).textSelection(.enabled)
            .accessibilityIdentifier("pair-verification-code")
    }
    private func payload(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let qr = qrImage(text) {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 260).frame(maxWidth: .infinity)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("配对二维码")
            } else {
                Text("这份资料较长，当前无法生成二维码；可使用下方复制与粘贴。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { UIPasteboard.general.string = text } label: {
                Label("复制配对载荷", systemImage: "doc.on.doc")
            }.accessibilityIdentifier("pair-copy")
            DisclosureGroup("查看原始配对资料") {
                Text(text).font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled).accessibilityIdentifier("pair-output")
            }
            Text("二维码只包含配对所需的公开资料；请只交给伴侣。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func qrImage(_ payload: String) -> UIImage? {
        guard let compact = try? PairingQRCode.encode(payload) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(compact.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    private func importPhoto(_ photo: PhotosPickerItem) async {
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw SpaceError.invalidInput }
            let regions: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1),
                                     CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
                                     CGRect(x: 0, y: 0, width: 1, height: 0.5),
                                     CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.6)]
            var scanned: String?
            for region in regions {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                request.regionOfInterest = region
                do { try VNImageRequestHandler(data: data).perform([request]) }
                catch { continue } // Some simulator runtimes cannot create Vision's inference context.
                scanned = request.results?.compactMap(\.payloadStringValue).first(where: { $0.hasPrefix("CPS1:") })
                if scanned != nil { break }
            }
            if scanned == nil, let image = CIImage(data: data),
               let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                         options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) {
                scanned = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                    .first(where: { $0.hasPrefix("CPS1:") })
            }
            guard let scanned else {
                model.error = "图片中未找到配对二维码。请使用完整、清晰的二维码截图。"
                selectedPhoto = nil
                return
            }
            input = try PairingQRCode.decode(scanned)
            model.error = nil
        } catch { model.error = "二维码资料无法读取。请重新选择原始截图，或改用复制配对载荷。" }
        selectedPhoto = nil
    }
}
#endif
