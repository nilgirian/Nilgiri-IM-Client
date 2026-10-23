import SwiftUI
import UIKit
import UserNotifications

@main
struct NilgiriIMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = IMSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .onAppear {
                    AppDelegate.session = session
                    clearDeliveredNotificationsAndBadge()
                }
                .task {
                    await session.restoreOnLaunch()
                    await PushRegistration.request(session: session)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                clearDeliveredNotificationsAndBadge()
            }
        }
    }
}

/// Launch and every return to the foreground. Delivered alerts are removed;
/// scheduled ones stay. The badge uses the iOS 16 API, then the older icon property.
private func clearDeliveredNotificationsAndBadge() {
    let center = UNUserNotificationCenter.current()
    center.removeAllDeliveredNotifications()
    if #available(iOS 16.0, *) {
        center.setBadgeCount(0)
    } else {
        UIApplication.shared.applicationIconBadgeNumber = 0
    }
}

struct RootView: View {
    @EnvironmentObject private var session: IMSession

    var body: some View {
        if session.token == nil {
            LoginView()
        } else {
            TranscriptView()
        }
    }
}
