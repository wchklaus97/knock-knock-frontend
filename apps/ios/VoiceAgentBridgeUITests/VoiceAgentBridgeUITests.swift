import Foundation
import XCTest

private struct UITestFixtureError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class UITestFixtureClient {
    private struct Response {
        let status: Int
        let body: [String: Any]
    }

    private let baseURL: URL
    private let email = "e2e-1785931570@local.test"
    private let password = "password123"

    static func configuredBaseURLString(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        [environment["KNOCK_UI_TEST_API_BASE_URL"], environment["KNOCK_API_BASE_URL"]]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? "http://127.0.0.1:8787"
    }

    init() throws {
        let configuredURL = Self.configuredBaseURLString()
        let normalizedURL = configuredURL.hasSuffix("/")
            ? String(configuredURL.dropLast())
            : configuredURL

        guard let url = URL(string: normalizedURL), url.scheme != nil, url.host != nil else {
            throw UITestFixtureError(message: "Invalid UI test API base URL: \(configuredURL)")
        }
        baseURL = url
    }

    func prepareNeedsUserFixture() async throws -> String {
        let token = try await ensureAccount()
        let nonce = UUID().uuidString.lowercased()
        let agentResponse = try await request(
            "/v1/agents",
            method: "POST",
            body: ["label": "ios-ui-\(nonce)", "host_label": "local"],
            bearer: token
        )
        guard (200..<300).contains(agentResponse.status),
              let agentKey = agentResponse.body["api_key"] as? String,
              !agentKey.isEmpty else {
            throw failure("create agent", response: agentResponse)
        }

        let sessionResponse = try await request(
            "/v1/sessions",
            method: "POST",
            body: [
                "skill_id": "deploy.result",
                "idempotency_key": "ios-ui-session-\(nonce)",
                "title": "Local UI needs user fixture",
                "chat_id": "ios-ui-chat-\(nonce)",
                "facts": ["service": "knock-knock", "environment": "local"]
            ],
            agentKey: agentKey
        )
        guard (200..<300).contains(sessionResponse.status),
              let sessionID = sessionResponse.body["session_id"] as? String,
              !sessionID.isEmpty else {
            throw failure("create session", response: sessionResponse)
        }

        let eventResponse = try await request(
            "/v1/sessions/\(sessionID)/events",
            method: "POST",
            body: [
                "status": "needs_user",
                "idempotency_key": "ios-ui-needs-user-\(nonce)",
                "facts": [
                    "status": "waiting",
                    "message": "Local UI fixture is waiting for a decision"
                ],
                "actions": ["rollback", "ack"]
            ],
            agentKey: agentKey
        )
        let eventSession = eventResponse.body["session"] as? [String: Any]
        guard (200..<300).contains(eventResponse.status),
              eventSession?["state"] as? String == "needs_user" else {
            throw failure("create needs_user event", response: eventResponse)
        }

        return sessionID
    }

    func prepareAccount() async throws {
        _ = try await ensureAccount()
    }

    private func ensureAccount() async throws -> String {
        let credentials = ["email": email, "password": password]
        let registration = try await request(
            "/v1/auth/register",
            method: "POST",
            body: credentials
        )
        if (200..<300).contains(registration.status),
           let token = registration.body["token"] as? String,
           !token.isEmpty {
            return token
        }
        guard registration.status == 409 else {
            throw failure("ensure local UI test account", response: registration)
        }

        let login = try await request(
            "/v1/auth/login",
            method: "POST",
            body: credentials
        )
        guard (200..<300).contains(login.status),
              let token = login.body["token"] as? String,
              !token.isEmpty else {
            throw failure("login local UI test account", response: login)
        }
        return token
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        bearer: String? = nil,
        agentKey: String? = nil
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw UITestFixtureError(message: "Invalid fixture endpoint: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let agentKey {
            request.setValue(agentKey, forHTTPHeaderField: "x-agent-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UITestFixtureError(message: "Fixture endpoint returned a non-HTTP response: \(path)")
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Response(status: httpResponse.statusCode, body: body)
    }

    private func failure(_ operation: String, response: Response) -> UITestFixtureError {
        let body = (try? JSONSerialization.data(withJSONObject: response.body))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        return UITestFixtureError(
            message: "Failed to \(operation) (HTTP \(response.status)): \(body)"
        )
    }
}

@MainActor
final class VoiceAgentBridgeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func signInIfNeeded(_ app: XCUIApplication) {
        let login = app.buttons["login.submit"]
        guard login.waitForExistence(timeout: 10) else {
            let alreadyAuthenticated = app.buttons["drawer.open"].waitForExistence(timeout: 30)
                || app.buttons["knock.review"].waitForExistence(timeout: 5)
            XCTAssertTrue(alreadyAuthenticated, "The app must show either login or the authenticated workspace.")
            return
        }

        // Debug builds start in sign-in mode with the local fixture password.
        // Never switch from sign-in to registration: the account is prepared
        // by UITestFixtureClient before each test. The fallback handles a
        // Release-like screen without silently submitting an empty password.
        let modeToggle = app.buttons["login.modeToggle"]
        if modeToggle.exists && modeToggle.label.contains("Already have an account") {
            modeToggle.tap()
            let password = app.secureTextFields.firstMatch
            if password.waitForExistence(timeout: 3) {
                password.tap()
                password.typeText("password123")
            }
        }

        login.tap()
        let dashboard = app.buttons["drawer.open"].waitForExistence(timeout: 30)
        let decision = app.buttons["knock.review"].waitForExistence(timeout: 5)
        XCTAssertTrue(dashboard || decision, "The local fixture account must authenticate successfully.")
    }

    private func dismissKnockIfPresent(_ app: XCUIApplication) {
        let later = app.buttons["knock.later"]
        let deadline = Date().addingTimeInterval(15)
        // The fixture is delivered asynchronously. Keep watching after the
        // workspace first appears so a late SSE/REST reconciliation cannot
        // place the full-screen knock overlay over the next assertion.
        while Date() < deadline {
            if later.exists {
                later.tap()
                _ = later.waitForNonExistence(timeout: 5)
                continue
            }
            if app.buttons["drawer.open"].exists {
                if later.waitForExistence(timeout: 2) { continue }
                return
            }
            _ = later.waitForExistence(timeout: 1)
        }
        XCTAssertFalse(later.exists, "The knock overlay must be dismissible before continuing.")
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchForIsolatedFixture(suppressKnockOverlay: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KNOCK_UI_TEST_RESET_AUTH"] = "1"
        // Avoid simulator notification banners interrupting drawer/settings
        // taps. In-app knock overlay behavior remains covered by the first
        // UI test, while APNs/banner behavior is validated separately.
        app.launchEnvironment["KNOCK_UI_TEST_SUPPRESS_LOCAL_BANNER"] = "1"
        if suppressKnockOverlay {
            app.launchEnvironment["KNOCK_UI_TEST_SUPPRESS_KNOCK_OVERLAY"] = "1"
        }
        // Pass the same endpoint explicitly to the application process. This
        // prevents a stale simulator UserDefaults value from winning over
        // the Worker selected by the fixture runner.
        let configuredURL = UITestFixtureClient.configuredBaseURLString()
        app.launchEnvironment["KNOCK_UI_TEST_API_BASE_URL"] = configuredURL
        app.launchEnvironment["KNOCK_API_BASE_URL"] = configuredURL
        app.launch()
        return app
    }

    func testDecisionSurfaceCompletesDestructiveConfirmationFlow() async throws {
        _ = try await UITestFixtureClient().prepareNeedsUserFixture()
        let app = launchForIsolatedFixture()

        // Keep the test repeatable on a clean simulator. The app ships with
        // the local demo account prefilled, so a fresh install only needs the
        // same visible sign-in action a user would take.
        signInIfNeeded(app)

        let review = app.buttons["knock.review"]
        XCTAssertTrue(
            review.waitForExistence(timeout: 45),
            "A fresh needs_user event must be present before running this flow."
        )
        review.tap()
        attachScreenshot(app, named: "decision-detail")

        let rollback = app.buttons["decision.action.rollback"]
        if !rollback.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(rollback.waitForExistence(timeout: 10))
        rollback.tap()

        let confirm = app.buttons["Confirm and continue"]
        // iPhone 17 presents the confirmation dialog after the navigation
        // transition has settled. Wait for the actual action instead of
        // treating the animation duration as a fixed five-second contract.
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        attachScreenshot(app, named: "command-confirmation")
        confirm.tap()

        XCTAssertTrue(
            app.staticTexts["Queued"].waitForExistence(timeout: 15),
            "The exact session should visibly move to queued after confirmation."
        )
        attachScreenshot(app, named: "command-queued")
    }

    func testSettingsGeneratesAndCopiesPairingCode() async throws {
        _ = try await UITestFixtureClient().prepareNeedsUserFixture()
        let app = launchForIsolatedFixture(suppressKnockOverlay: true)
        signInIfNeeded(app)
        dismissKnockIfPresent(app)

        let menu = app.buttons["drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()

        dismissKnockIfPresent(app)
        XCTAssertTrue(app.buttons["drawer.home"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["drawer.sessions"].waitForExistence(timeout: 15))
        let settings = app.buttons["drawer.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        attachScreenshot(app, named: "settings-sheet")

        let pair = app.buttons["settings.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 15))
        pair.tap()

        let generate = app.buttons["pairing.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 15))
        generate.tap()

        let copy = app.buttons["Copy pairing code"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15))
        copy.tap()
        XCTAssertTrue(app.buttons["Pairing code copied"].waitForExistence(timeout: 5))
    }

    func testHomeScopesAndAgentRowsStayUsable() async throws {
        _ = try await UITestFixtureClient().prepareNeedsUserFixture()
        let app = launchForIsolatedFixture(suppressKnockOverlay: true)
        signInIfNeeded(app)
        dismissKnockIfPresent(app)
        attachScreenshot(app, named: "home-today")

        let today = app.segmentedControls.buttons["Today"]
        XCTAssertTrue(today.waitForExistence(timeout: 15))
        XCTAssertTrue(app.segmentedControls.buttons["This week"].exists)
        XCTAssertTrue(app.staticTexts["Today"].exists)

        dismissKnockIfPresent(app)
        let thisWeek = app.segmentedControls.buttons["This week"]
        XCTAssertTrue(thisWeek.waitForExistence(timeout: 15))
        XCTAssertTrue(thisWeek.isHittable, "The workspace must be unobstructed before changing scope.")
        thisWeek.tap()
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 15))
        attachScreenshot(app, named: "home-this-week")

        let menu = app.buttons["drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        // The drawer uses a full-height transition on larger devices. Wait
        // for its anchored footer and section label after the transition.
        XCTAssertTrue(app.buttons["drawer.home"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["PINNED"].waitForExistence(timeout: 15))
        attachScreenshot(app, named: "drawer")
    }

    func testPhysicalVoiceProductionPath() async throws {
        guard ProcessInfo.processInfo.environment["KNOCK_RUN_PHYSICAL_VOICE_E2E"] == "1" else {
            throw XCTSkip("Opt-in physical voice UAT is disabled")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical microphone, signed-model, and TTS UAT requires an iPhone")
        #else
        try await UITestFixtureClient().prepareAccount()
        let app = launchForIsolatedFixture()
        signInIfNeeded(app)
        dismissKnockIfPresent(app)

        let menu = app.buttons["drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()

        let settings = app.buttons["drawer.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let voice = app.buttons["settings.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 15))
        voice.tap()

        let ready = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ AND NOT label CONTAINS %@",
                "Ready · Gemma",
                "Update failed"
            )
        ).firstMatch
        let prepareOrRefresh = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "Prepare voice model",
                "Refresh voice model"
            )
        ).firstMatch
        XCTAssertTrue(
            prepareOrRefresh.waitForExistence(timeout: 10),
            "The Voice settings panel must expose model preparation."
        )
        prepareOrRefresh.tap()
        let preparing = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Preparing")
        ).firstMatch
        _ = preparing.waitForExistence(timeout: 15)
        XCTAssertTrue(
            ready.waitForExistence(timeout: 240),
            "The production model manager must download and verify a signed Gemma model."
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Update failed"))
                .firstMatch.exists,
            "A stale model must not hide a failed forced refresh."
        )
        attachScreenshot(app, named: "physical-voice-model-ready")

        let panelDone = app.navigationBars["Voice"].buttons["Done"]
        XCTAssertTrue(panelDone.waitForExistence(timeout: 10))
        panelDone.tap()
        let settingsDone = app.buttons["settings.done"]
        XCTAssertTrue(settingsDone.waitForExistence(timeout: 10))
        settingsDone.tap()

        let dock = app.descendants(matching: .any)["voice.dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 30))

        // A fresh physical install can show the Speech Recognition and
        // microphone prompts only after the first press. Prime those prompts
        // before the measured recording; otherwise releasing the first press
        // correctly cancels a session that is still waiting for permission.
        var handledVoicePermission = false
        addUIInterruptionMonitor(withDescription: "Voice permissions") { alert in
            let allow = alert.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@ OR label == %@",
                    "Allow",
                    "Allow While Using App",
                    "OK"
                )
            ).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            handledVoicePermission = true
            return true
        }
        dock.press(forDuration: 1)
        app.tap()
        if handledVoicePermission {
            // Speech and microphone authorization can arrive as two separate
            // system prompts. A second prime pass handles the remaining one.
            dock.press(forDuration: 1)
            app.tap()
        }
        Thread.sleep(forTimeInterval: 1)

        let configuredCountdown = Int(
            ProcessInfo.processInfo.environment["KNOCK_PHYSICAL_VOICE_COUNTDOWN_SECONDS"] ?? "5"
        ) ?? 5
        let countdown = min(max(configuredCountdown, 3), 30)
        print("[physical-voice-uat] SPEAK NOW in \(countdown)s: Show me what happened today")
        Thread.sleep(forTimeInterval: TimeInterval(countdown))
        dock.press(forDuration: 6)

        let terminal = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "voice.command.presentation",
                "History search completed. Review the results on screen."
            )
        ).firstMatch
        let resultDeadline = Date().addingTimeInterval(120)
        while Date() < resultDeadline && !terminal.exists {
            // The account fixture can reconcile a pending decision after the
            // initial preflight dismissal. Keep that unrelated overlay from
            // obscuring the backend-owned voice result during physical UAT.
            let later = app.buttons["knock.later"]
            if later.exists {
                later.tap()
                _ = later.waitForNonExistence(timeout: 5)
                continue
            }
            _ = terminal.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(
            terminal.exists,
            "Only the backend-owned history_search.completed presentation is a success oracle."
        )
        attachScreenshot(app, named: "physical-voice-backend-result")
        print("[physical-voice-uat] Human must confirm that TTS said: History search completed.")
        #endif
    }
}
