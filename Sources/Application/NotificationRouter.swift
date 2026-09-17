#if os(iOS)
import UIKit
import Combine
import UserNotifications
import Domain

public struct AffectionNotificationAction: Identifiable, Sendable {
    public let id = UUID()
    public let envelopeID: UUID
    public let respond: Bool
}

@MainActor public final class SpaceNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    public static let shared = SpaceNotificationDelegate()
    @Published public var destination: NotificationDestination?
    @Published public var affectionAction: AffectionNotificationAction?
    @Published public var pushToken: String?
    @Published public var pushRegistrationFailed = false
    public var backgroundSync: (() async -> Bool)?
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = Self.shared
        Self.shared.backgroundSync = { await NetworkSpaceModel.shared.backgroundRefresh() }
        let response = UNNotificationAction(identifier: "RESPOND_AFFECTION", title: "回应这份心意", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "PRIVATE_AFFECTION", actions: [response], intentIdentifiers: [])
        ])
        if ["affection-push-enabled", "message-push-enabled", "wish-push-enabled"].contains(where: { UserDefaults.standard.object(forKey: $0) as? Bool ?? true }) {
            application.registerForRemoteNotifications()
        }
        return true
    }
    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.shared.pushToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.shared.pushRegistrationFailed = false
    }
    public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.shared.pushRegistrationFailed = true
    }
    public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard let run = Self.shared.backgroundSync else { completionHandler(.noData); return }
            completionHandler(await run() ? .newData : .failed)
        }
    }
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let raw = info["affection_envelope"] as? String, let id = UUID(uuidString: raw),
           [UNNotificationDefaultActionIdentifier, "RESPOND_AFFECTION"].contains(response.actionIdentifier) {
            let wantsReply = response.actionIdentifier == "RESPOND_AFFECTION"
            Task { @MainActor in Self.shared.affectionAction = AffectionNotificationAction(envelopeID: id, respond: wantsReply) }
            completionHandler(); return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let raw = info["destination"] as? String, let kind = NotificationDestination.Kind(rawValue: raw) {
            let id = (info["object_id"] as? String).flatMap(UUID.init(uuidString:))
            Task { @MainActor in Self.shared.destination = NotificationDestination(kind: kind, objectID: id) }
        }
        completionHandler()
    }
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo["affection_envelope"] != nil ||
            (notification.request.trigger is UNPushNotificationTrigger && notification.request.content.userInfo["destination"] != nil) {
            // The foreground app displays the verified encrypted interaction itself.
            completionHandler([]); return
        }
        completionHandler([.banner, .sound])
    }
}
#endif
