import Foundation
import UIKit
import UserNotifications

enum PushRegistration {
    private static var pendingHex: String?
    private static var pendingEnv: String?

    @MainActor
    static func request(session: IMSession) async {
        let center = UNUserNotificationCenter.current()
        do {
            let ok = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            guard ok else { return }
            UIApplication.shared.registerForRemoteNotifications()
            await flush(session: session)
        } catch {
            session.status = error.localizedDescription
        }
    }

    @MainActor
    static func flush(session: IMSession) async {
        guard session.token != nil, let hex = pendingHex, let env = pendingEnv else { return }
        await session.registerDevice(token: hex, environment: env)
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func remember(hex: String, environment: String) {
        pendingHex = hex
        pendingEnv = environment
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var session: IMSession?

    /// The transcript and login screens are black with `.preferredColorScheme(.dark)`.
    /// SwiftUI has no keyboard modifier, so the text fields pick up a dark keyboard here.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UITextField.appearance().keyboardAppearance = .dark
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        let hex = PushRegistration.hex(deviceToken)
        PushRegistration.remember(hex: hex, environment: env)
        Task { @MainActor in
            guard let session = AppDelegate.session else { return }
            await PushRegistration.flush(session: session)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            AppDelegate.session?.status = "Push token failed: \(error.localizedDescription)"
        }
    }
}
