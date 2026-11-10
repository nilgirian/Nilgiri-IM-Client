import SwiftUI
import UIKit
import UserNotifications

private struct LaunchSplashVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the white launch cover is on screen. The command field
    /// waits to become first responder until this drops.
    var launchSplashVisible: Bool {
        get { self[LaunchSplashVisibleKey.self] }
        set { self[LaunchSplashVisibleKey.self] = newValue }
    }
}

@main
struct NilgiriIMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = IMSession()
    /// Launch cover only. Session restore starts in the same appearance and is not gated on this.
    @State private var showLaunchSplash = true

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environment(\.launchSplashVisible, showLaunchSplash)
                .accessibilityHidden(showLaunchSplash)
                .onAppear {
                    AppDelegate.session = session
                    clearDeliveredNotificationsAndBadge(session)
                }
                .task {
                    await session.restoreOnLaunch()
                    await PushRegistration.request(session: session)
                }
                .task {
                    guard showLaunchSplash else { return }
                    do {
                        try await Task.sleep(for: .seconds(3))
                    } catch {
                        return
                    }
                    showLaunchSplash = false
                }
                .overlay {
                    ZStack {
                        if showLaunchSplash {
                            LaunchSplash()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.35), value: showLaunchSplash)
                    .allowsHitTesting(showLaunchSplash)
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

/// White cover over the root for about three seconds, then a short fade.
/// Display name, version, and build are read from the generated Info.plist.
/// The app credit and the world credit sit between those two lines.
/// Black on white stays the same in light and dark mode.
private struct LaunchSplash: View {
    @StateObject private var matrixMode = MatrixMode.shared

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text(appName)
                        .font(.title2.weight(.semibold))
                    Text("by Frederick Nacino")
                        .font(.subheadline)
                }
                VStack(spacing: 4) {
                    Text("Nilgiri the Forgotten World")
                        .font(.title3.bold())
                    Text("by")
                        .font(.subheadline)
                    Text("Frederick Nacino and Robert Jeremy Bogue")
                        .font(.subheadline)
                }
                Text(versionLine)
                    .font(.subheadline)
            }
            .foregroundStyle(MatrixShade.display(Color.black, enabled: matrixMode.enabled))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
    }

    /// `CFBundleDisplayName` ("Nilgiri IM").
    private var appName: String {
        bundleString("CFBundleDisplayName")
    }

    /// "Version <CFBundleShortVersionString> (build <CFBundleVersion>)".
    private var versionLine: String {
        let version = bundleString("CFBundleShortVersionString")
        let build = bundleString("CFBundleVersion")
        return "Version \(version) (build \(build))"
    }

    private func bundleString(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? ""
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
