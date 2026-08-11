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
        .sheet(item: $store.pendingCommandConfirmation) { confirmation in
            ProductionCommandConfirmationSheet(confirmation: confirmation)
                .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundReconciliationRequested)) { notification in
            guard let request = notification.object as? BackgroundReconciliationRequest,
                  request.claim()
            else { return }
            guard store.token != nil else {
                request.complete(.noData)
                return
            }

            // APNs carries only a wake hint. REST remains authoritative for
            // every command, session, and presentation field.
            Task { @MainActor in
                defer { request.complete(.newData) }
                await store.refresh(includeAgents: false)
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                guard store.token != nil else { return }
                store.startEventStream()
                Task { await store.refresh() }
            case .inactive:
                store.voiceController?.abort()
            case .background:
                store.voiceController?.abort()
                store.stopEventStream()
            @unknown default:
                store.voiceController?.abort()
            }
        }
    }
}
