import SwiftUI

@main
struct NilgiriIMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = IMSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .onAppear {
                    AppDelegate.session = session
                }
                .task {
                    await session.restoreOnLaunch()
                    await PushRegistration.request(session: session)
                }
        }
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
