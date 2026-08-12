import UIKit
import XCTest
@testable import VoiceAgentBridge

final class BackgroundRemoteNotificationTests: XCTestCase {
    func testCommandHintSchedulesReconciliationAndCompletesWithNewData() {
        let dispatcher = BackgroundReconciliationDispatcher()
        let delegate = AppDelegate(
            backgroundReconciliationDispatcher: dispatcher,
            backgroundCompletionTimeout: 60
        )

        var receivedHints: [RemoteNotificationWakeHint] = []
        dispatcher.bind { request in
            receivedHints.append(request.hint)
            XCTAssertTrue(request.claim())
            request.complete(.newData)
        }

        var completionResults: [UIBackgroundFetchResult] = []
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [
                "aps": ["content-available": 1],
                "wake_hint": "command",
                "command": ["display_text": "untrusted APNs business data"],
            ],
            fetchCompletionHandler: { completionResults.append($0) }
        )

        XCTAssertEqual(receivedHints, [.command])
        XCTAssertEqual(completionResults, [.newData])
    }

    func testSessionHintReceivedBeforeBindingIsReplayedForReconciliation() {
        let dispatcher = BackgroundReconciliationDispatcher()
        let delegate = AppDelegate(
            backgroundReconciliationDispatcher: dispatcher,
            backgroundCompletionTimeout: 60
        )

        var receivedHints: [RemoteNotificationWakeHint] = []
        var completionResults: [UIBackgroundFetchResult] = []
        delegate.handleRemoteNotification(
            [
                "aps": ["content-available": 1],
                "session_id": "ses_wake_only",
                "title": "untrusted APNs title",
            ],
            fetchCompletionHandler: { completionResults.append($0) }
        )
        XCTAssertTrue(receivedHints.isEmpty)
        XCTAssertTrue(completionResults.isEmpty)

        dispatcher.bind { request in
            receivedHints.append(request.hint)
            XCTAssertTrue(request.claim())
            request.complete(.newData)
        }

        XCTAssertEqual(receivedHints, [.session])
        XCTAssertEqual(completionResults, [.newData])
    }

    func testMalformedPayloadCompletesWithNoDataWithoutSchedulingReconciliation() {
        let dispatcher = BackgroundReconciliationDispatcher()
        let delegate = AppDelegate(
            backgroundReconciliationDispatcher: dispatcher,
            backgroundCompletionTimeout: 60
        )

        var reconciliationCount = 0
        dispatcher.bind { _ in
            reconciliationCount += 1
        }

        var completionResults: [UIBackgroundFetchResult] = []
        delegate.handleRemoteNotification(
            [
                "aps": ["content-available": 1],
                "wake_hint": "message",
                "body": "untrusted APNs body",
            ],
            fetchCompletionHandler: { completionResults.append($0) }
        )

        XCTAssertEqual(reconciliationCount, 0)
        XCTAssertEqual(completionResults, [.noData])
    }

    func testBackgroundFetchCompletionRunsExactlyOnce() {
        var completionResults: [UIBackgroundFetchResult] = []
        let request = BackgroundReconciliationRequest(hint: .command) {
            completionResults.append($0)
        }

        XCTAssertTrue(request.claim())
        XCTAssertFalse(request.claim())
        request.complete(.newData)
        request.complete(.failed)
        request.complete(.noData)

        XCTAssertEqual(completionResults, [.newData])

        var timeoutResults: [UIBackgroundFetchResult] = []
        let timedOutRequest = BackgroundReconciliationRequest(hint: .session) {
            timeoutResults.append($0)
        }
        XCTAssertTrue(timedOutRequest.claim())
        timedOutRequest.complete(.failed)
        timedOutRequest.complete(.newData)
        XCTAssertEqual(timeoutResults, [.failed])
    }

    func testBackgroundFetchResultReflectsAuthRefreshAndCursorChange() {
        XCTAssertEqual(
            AppStore.backgroundFetchResult(
                authenticated: false,
                refreshCompleted: false,
                cursorChanged: false
            ),
            .noData
        )
        XCTAssertEqual(
            AppStore.backgroundFetchResult(
                authenticated: true,
                refreshCompleted: false,
                cursorChanged: false
            ),
            .failed
        )
        XCTAssertEqual(
            AppStore.backgroundFetchResult(
                authenticated: true,
                refreshCompleted: true,
                cursorChanged: false
            ),
            .noData
        )
        XCTAssertEqual(
            AppStore.backgroundFetchResult(
                authenticated: true,
                refreshCompleted: true,
                cursorChanged: true
            ),
            .newData
        )
    }
}
