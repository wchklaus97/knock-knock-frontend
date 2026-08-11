import UIKit
import XCTest
@testable import VoiceAgentBridge

final class BackgroundRemoteNotificationTests: XCTestCase {
    func testCommandHintSchedulesReconciliationAndCompletesWithNewData() {
        let center = NotificationCenter()
        let delegate = AppDelegate(
            notificationCenter: center,
            backgroundCompletionTimeout: 60
        )
        delegate.activateBackgroundReconciliationDelivery()

        var receivedHints: [RemoteNotificationWakeHint] = []
        let observer = center.addObserver(
            forName: .backgroundReconciliationRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard let request = notification.object as? BackgroundReconciliationRequest else {
                return XCTFail("Expected a background reconciliation request")
            }
            receivedHints.append(request.hint)
            XCTAssertTrue(request.claim())
            request.complete(.newData)
        }
        defer { center.removeObserver(observer) }

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
        let center = NotificationCenter()
        let delegate = AppDelegate(
            notificationCenter: center,
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

        let observer = center.addObserver(
            forName: .backgroundReconciliationRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard let request = notification.object as? BackgroundReconciliationRequest else {
                return XCTFail("Expected a background reconciliation request")
            }
            receivedHints.append(request.hint)
            XCTAssertTrue(request.claim())
            request.complete(.newData)
        }
        defer { center.removeObserver(observer) }

        delegate.activateBackgroundReconciliationDelivery()

        XCTAssertEqual(receivedHints, [.session])
        XCTAssertEqual(completionResults, [.newData])
    }

    func testMalformedPayloadCompletesWithNoDataWithoutSchedulingReconciliation() {
        let center = NotificationCenter()
        let delegate = AppDelegate(
            notificationCenter: center,
            backgroundCompletionTimeout: 60
        )
        delegate.activateBackgroundReconciliationDelivery()

        var reconciliationCount = 0
        let observer = center.addObserver(
            forName: .backgroundReconciliationRequested,
            object: nil,
            queue: nil
        ) { _ in
            reconciliationCount += 1
        }
        defer { center.removeObserver(observer) }

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
}
