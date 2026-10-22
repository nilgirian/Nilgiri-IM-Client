import Foundation
import UIKit
import UserNotifications

enum PushRegistration {
    @MainActor
    static func request(session: IMSession) async {
        let center = UNUserNotificationCenter.current()
        do {
            let ok = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            guard ok else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            session.status = error.localizedDescription
        }
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var session: IMSession?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            guard let session = AppDelegate.session, session.token != nil else { return }
            #if DEBUG
            let env = "sandbox"
            #else
            let env = "production"
            #endif
            await session.registerDevice(token: PushRegistration.hex(deviceToken), environment: env)
        }
    }
}
