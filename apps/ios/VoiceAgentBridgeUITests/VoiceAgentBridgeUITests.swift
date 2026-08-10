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

    init() throws {
        let configuredURL = ProcessInfo.processInfo.environment["KNOCK_UI_TEST_API_BASE_URL"]
            ?? ProcessInfo.processInfo.environment["KNOCK_API_BASE_URL"]
            ?? "http://127.0.0.1:8787"
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
        if later.waitForExistence(timeout: 5) {
            later.tap()
        }
    }

    private func launchForIsolatedFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KNOCK_UI_TEST_RESET_AUTH"] = "1"
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

        let rollback = app.buttons["decision.action.rollback"]
        if !rollback.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(rollback.waitForExistence(timeout: 10))
        rollback.tap()

        let confirm = app.buttons["Confirm and continue"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(
            app.staticTexts["Queued"].waitForExistence(timeout: 15),
            "The exact session should visibly move to queued after confirmation."
        )
    }

    func testSettingsGeneratesAndCopiesPairingCode() async throws {
        _ = try await UITestFixtureClient().prepareNeedsUserFixture()
        let app = launchForIsolatedFixture()
        signInIfNeeded(app)
        dismissKnockIfPresent(app)

        let menu = app.buttons["drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()

        XCTAssertTrue(app.buttons["drawer.dashboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["drawer.sessions"].waitForExistence(timeout: 5))
        let settings = app.buttons["drawer.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let generate = app.buttons["pairing.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 15))
        generate.tap()

        let copy = app.buttons["Copy pairing code"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15))
        copy.tap()
        XCTAssertTrue(app.buttons["Pairing code copied"].waitForExistence(timeout: 5))
    }

    func testDashboardSearchAndFiltersStayUsable() async throws {
        _ = try await UITestFixtureClient().prepareNeedsUserFixture()
        let app = launchForIsolatedFixture()
        signInIfNeeded(app)
        dismissKnockIfPresent(app)

        let search = app.textFields["inbox.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["filter.needs_user"].exists)
        XCTAssertTrue(app.buttons["filter.active"].exists)
        XCTAssertTrue(app.buttons["filter.all"].exists)

        search.tap()
        search.typeText("not-a-real-session")
        XCTAssertTrue(app.staticTexts["Nothing matches"].waitForExistence(timeout: 5))

        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["Recent sessions"].waitForExistence(timeout: 5))
    }
}
