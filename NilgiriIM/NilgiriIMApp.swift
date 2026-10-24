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
                    clearDeliveredNotificationsAndBadge(session)
                }
                .task {
                    await session.restoreOnLaunch()
                    await PushRegistration.request(session: session)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                clearDeliveredNotificationsAndBadge(session)
            }
        }
    }
}

/// Launch and every return to the foreground. Delivered alerts are removed;
/// scheduled ones stay. The badge uses the iOS 16 API, then the older icon property.
/// The server counter is cleared after that when a session is already open.
private func clearDeliveredNotificationsAndBadge(_ session: IMSession) {
    let center = UNUserNotificationCenter.current()
    center.removeAllDeliveredNotifications()
    if #available(iOS 16.0, *) {
        center.setBadgeCount(0)
    } else {
        UIApplication.shared.applicationIconBadgeNumber = 0
    }
    // IMSession is @MainActor. This helper is a nonisolated free function.
    Task { @MainActor in
        session.resetServerBadge()
    }
}

struct RootView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.token != nil {
                TranscriptView()
            } else if session.creating {
                CharacterCreateView()
            } else {
                LoginView()
            }
        }
        .onAppear {
            syncOrientationLock()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && session.creating && session.createStep?.isPassword != true {
                session.cancelCharacterCreation()
            }
        }
        .onChange(of: session.token) { _, _ in
            syncOrientationLock()
        }
        .onChange(of: session.creating) { _, _ in
            syncOrientationLock()
        }
        .onChange(of: session.createGreeting == nil) { _, _ in
            syncOrientationLock()
        }
        .alert(
            session.outageAlert?.message ?? "",
            isPresented: Binding(
                get: { session.outageAlert != nil },
                set: { shown in
                    if shown == false {
                        session.acknowledgeOutage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                session.acknowledgeOutage()
            }
            Button("Retry") {
                Task { await session.retryOutage() }
            }
        }
    }

    /// Login and the name/email form are portrait on iPhone. Wizard steps
    /// rotate once the greeting is showing. The transcript and iPad stay free.
    private func syncOrientationLock() {
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let portraitOnly = phone && session.token == nil
            && (session.creating == false || session.createGreeting == nil)
        AppDelegate.orientationLock = portraitOnly ? .portrait : .all
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if portraitOnly {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
            let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController
            root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
