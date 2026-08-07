import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                if store.token == nil {
                    ProductionLoginView()
                } else {
                    ProductionMainShellView()
                }
            }

            if let knock = store.knockAlert {
                ProductionKnockOverlay(
                    knock: knock,
                    onOpenSession: {
                        store.knockAlert = nil
                        if let sessionId = knock.sessionId {
                            Task { await store.openSession(sessionId) }
                        }
                    },
                    onDismiss: {
                        store.knockAlert = nil
                    }
                )
                .transition(.opacity)
                .zIndex(999)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.knockAlert?.id)
        .onChange(of: scenePhase) { phase in
            guard phase == .active, store.token != nil else { return }
            store.startPolling()
            Task { await store.refresh() }
        }
    }
}
