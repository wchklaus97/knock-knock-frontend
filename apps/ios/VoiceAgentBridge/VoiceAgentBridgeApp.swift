import SwiftUI

@main
struct VoiceAgentBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    store.bindPush(appDelegate)
                    appDelegate.requestPushAuthorization()
                    store.bootstrapIfLoggedIn()
                }
                .onChange(of: store.token) { new in
                    if new != nil {
                        appDelegate.requestPushAuthorization()
                        store.bootstrapIfLoggedIn()
                    }
                }
        }
    }
}
