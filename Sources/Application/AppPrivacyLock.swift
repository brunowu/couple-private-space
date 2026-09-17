#if os(iOS)
import Foundation
import LocalAuthentication

@MainActor final class AppPrivacyLock: ObservableObject {
    private static let setting = "private-app-lock-enabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var unlocked: Bool
    @Published private(set) var error: String?
    private var authenticating = false

    init() {
        let saved = UserDefaults.standard.bool(forKey: Self.setting)
        enabled = saved
        unlocked = !saved
    }

    func becameInactive() {
        if enabled { unlocked = false }
    }

    func becameActive() async {
        if enabled && !unlocked { await unlock() }
    }

    func unlock() async {
        guard enabled, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        do {
            try await authenticate()
            unlocked = true
            error = nil
        } catch {
            unlocked = false
            self.error = "暂时无法解锁。请使用设备密码或稍后重试。"
        }
    }

    func setEnabled(_ next: Bool) async throws {
        guard next != enabled else { return }
        if next {
            try await authenticate()
            UserDefaults.standard.set(true, forKey: Self.setting)
            enabled = true
            unlocked = true
        } else {
            guard unlocked else { throw CocoaError(.userCancelled) }
            UserDefaults.standard.set(false, forKey: Self.setting)
            enabled = false
            unlocked = true
        }
        error = nil
    }

    private func authenticate() async throws {
        let context = LAContext()
        var availability: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availability) else {
            throw availability ?? CocoaError(.featureUnsupported)
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                               localizedReason: "解锁两个人的私密空间") else {
            throw CocoaError(.userCancelled)
        }
    }
}
#endif
