import Foundation
import XCTest

private struct UITestFixtureError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum PhysicalVoiceCaptureMode: String {
    case automated
    case manual
}

private enum PhysicalVoiceExpectationMode: String {
    case history
    case highRisk = "high-risk"
    case clarification
}

private final class UITestFixtureClient {
    private struct Response {
        let status: Int
        let body: [String: Any]
    }

    struct CommandDetail {
        let commandID: String
        let state: String
        let intent: String
        let idempotencyKey: String
        let riskLevel: String
        let needsConfirmation: Bool
        let version: Int?
        let hasNonNullResult: Bool
        fileprivate let envelope: [String: Any]
        fileprivate let canonicalEnvelope: Data
        fileprivate let canonicalResult: Data?
    }

    private let baseURL: URL
    private let email = "e2e-1785931570@local.test"
    private let password = "password123"
    private var bearerToken: String?

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

    static func isApprovedPhysicalVoiceBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
        let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased()
        else { return false }

        if scheme == "https",
           components.port == nil,
           host == "knock-knock-backend-staging.wch-klaus.workers.dev"
        {
            return true
        }

        guard scheme == "http", isRFC1918IPv4(host) else { return false }
        return true
    }

    private static func isRFC1918IPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { component -> Int? in
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  (component == "0" || component.first != "0"),
                  let value = Int(component),
                  (0...255).contains(value)
            else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    init() throws {
        let configuredURL = Self.configuredBaseURLString()
        let normalizedURL = configuredURL.hasSuffix("/")
            ? String(configuredURL.dropLast())
            : configuredURL

        guard let url = URL(string: normalizedURL), url.scheme != nil, url.host != nil else {
            throw UITestFixtureError(message: "Invalid UI test API base URL; value redacted")
        }
        baseURL = url
    }

    func requireActionProviderDisabled() async throws {
        let response = try await request("/health")
        guard (200..<300).contains(response.status),
              response.body["ok"] as? Bool == true,
              response.body["action_provider_ready"] as? Bool == false else {
            throw failure("verify fail-closed action provider health", response: response)
        }
    }

    func prepareNeedsUserFixture(
        title: String = "Local UI needs user fixture"
    ) async throws -> String {
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
                "title": title,
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

    func latestSessionExpectation() async throws -> (id: String, title: String) {
        let token = try await ensureAccount()
        let response = try await request(
            "/v1/phone/sessions?limit=1",
            bearer: token
        )
        guard (200..<300).contains(response.status),
              let sessions = response.body["sessions"] as? [[String: Any]],
              let session = sessions.first,
              let sessionID = session["session_id"] as? String,
              !sessionID.isEmpty,
              let title = session["title"] as? String,
              !title.isEmpty else {
            throw failure("load latest session for convergence UAT", response: response)
        }
        return (sessionID, title)
    }

    func commandIDs() async throws -> Set<String> {
        let token = try await ensureAccount()
        var commandIDs = Set<String>()
        var before: String?
        var seenCursors = Set<String>()

        for _ in 0..<200 {
            var components = URLComponents()
            components.path = "/v1/phone/commands"
            components.queryItems = [URLQueryItem(name: "limit", value: "50")]
            if let before {
                components.queryItems?.append(URLQueryItem(name: "before", value: before))
            }
            guard let path = components.string else {
                throw UITestFixtureError(message: "Could not construct the command-list endpoint")
            }

            let response = try await request(path, bearer: token)
            guard (200..<300).contains(response.status),
                  let commands = response.body["commands"] as? [[String: Any]],
                  let hasMore = response.body["has_more"] as? Bool else {
                throw failure("list commands", response: response)
            }
            for command in commands {
                guard let commandID = command["command_id"] as? String,
                      !commandID.isEmpty else {
                    throw failure("read command summary", response: response)
                }
                commandIDs.insert(commandID)
            }
            guard hasMore else { return commandIDs }
            guard let nextCursor = response.body["next_cursor"] as? String,
                  !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else {
                throw UITestFixtureError(message: "Command pagination did not advance safely")
            }
            before = nextCursor
        }

        throw UITestFixtureError(message: "Command pagination exceeded the fixture safety limit")
    }

    func commandDetail(commandID: String) async throws -> CommandDetail {
        let token = try await ensureAccount()
        let path = try commandPath(commandID)
        let response = try await request(path, bearer: token)
        return try parseCommandDetail(
            response,
            operation: "read command detail",
            expectedCommandID: commandID
        )
    }

    func replayCanonicalCommandForRowProof(_ detail: CommandDetail) async throws -> CommandDetail {
        let token = try await ensureAccount()
        let response = try await request(
            "/v1/phone/commands",
            method: "POST",
            body: detail.envelope,
            bearer: token
        )
        return try parseCommandDetail(
            response,
            operation: "replay command",
            expectedCommandID: detail.commandID
        )
    }

    private func parseCommandDetail(
        _ response: Response,
        operation: String,
        expectedCommandID: String
    ) throws -> CommandDetail {
        guard (200..<300).contains(response.status),
              let commandID = response.body["command_id"] as? String,
              commandID == expectedCommandID,
              let state = response.body["state"] as? String,
              !state.isEmpty,
              let envelope = response.body["command"] as? [String: Any],
              let envelopeCommandID = envelope["command_id"] as? String,
              envelopeCommandID == commandID,
              let intent = envelope["intent"] as? String,
              !intent.isEmpty,
              let idempotencyKey = envelope["idempotency_key"] as? String,
              !idempotencyKey.isEmpty,
              let riskLevel = envelope["risk_level"] as? String,
              !riskLevel.isEmpty,
              let needsConfirmation = envelope["needs_confirmation"] as? Bool,
              JSONSerialization.isValidJSONObject(envelope) else {
            throw failure(operation, response: response)
        }
        let canonicalEnvelope = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )
        let result = response.body["result"]
        let canonicalResult = try result.map {
            try JSONSerialization.data(
                withJSONObject: $0,
                options: [.fragmentsAllowed, .sortedKeys]
            )
        }
        return CommandDetail(
            commandID: commandID,
            state: state,
            intent: intent,
            idempotencyKey: idempotencyKey,
            riskLevel: riskLevel,
            needsConfirmation: needsConfirmation,
            version: response.body["version"] as? Int,
            hasNonNullResult: result != nil && !(result is NSNull),
            envelope: envelope,
            canonicalEnvelope: canonicalEnvelope,
            canonicalResult: canonicalResult
        )
    }

    private func commandPath(_ commandID: String) throws -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        guard !commandID.isEmpty,
              commandID.count <= 128,
              commandID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw UITestFixtureError(message: "Command id is not safe for a fixture endpoint")
        }
        return "/v1/phone/commands/\(commandID)"
    }

    private func ensureAccount() async throws -> String {
        if let bearerToken { return bearerToken }

        let credentials = ["email": email, "password": password]
        let registration = try await request(
            "/v1/auth/register",
            method: "POST",
            body: credentials
        )
        if (200..<300).contains(registration.status),
           let token = registration.body["token"] as? String,
           !token.isEmpty {
            bearerToken = token
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
        bearerToken = token
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
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
        return UITestFixtureError(
            message: "Failed to \(operation) (HTTP \(response.status)); response body redacted"
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

    /// A physical device can briefly lose its route while XCTest relaunches
    /// the app (for example while Wi-Fi or a VPN tunnel is settling). Exercise
    /// the same visible retry control a user has instead of treating one
    /// transient 15-second request timeout as a product failure.
    private func waitForDecisionReview(
        _ app: XCUIApplication,
        timeout: TimeInterval = 90
    ) -> Bool {
        let review = app.buttons["knock.review"]
        let retry = app.buttons["home.connection.retry"]
        let deadline = Date().addingTimeInterval(timeout)
        var retries = 0

        while Date() < deadline {
            if review.exists { return true }

            if retries < 3,
               retry.waitForExistence(timeout: 2),
               retry.isHittable
            {
                retry.tap()
                retries += 1
                if review.waitForExistence(timeout: 20) { return true }
                continue
            }

            _ = review.waitForExistence(timeout: 2)
        }
        return review.exists
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

    /// Relaunches the application without clearing Keychain or SQLite. This is
    /// intentionally separate from the repeatable fixture launcher because a
    /// physical airplane-mode drill must prove that the real authenticated
    /// cache survives process termination and a missing network route.
    private func launchPreservingPhysicalState() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KNOCK_UI_TEST_SUPPRESS_LOCAL_BANNER"] = "1"
        app.launchEnvironment["KNOCK_UI_TEST_SUPPRESS_KNOCK_OVERLAY"] = "1"
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
        guard waitForDecisionReview(app) else {
            attachScreenshot(app, named: "decision-fixture-unavailable")
            XCTFail("A fresh needs_user event must be present before running this flow.")
            return
        }
        review.tap()
        attachScreenshot(app, named: "decision-detail")

        let rollback = app.buttons["decision.action.rollback"]
        XCTAssertTrue(rollback.waitForExistence(timeout: 10))
        var scrollAttempts = 0
        while !rollback.isHittable && scrollAttempts < 4 {
            app.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(
            rollback.isHittable,
            "The destructive action must be scrolled into the visible viewport before tapping."
        )
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

    func testLatestSessionConvergesOnPhysicalDevice() async throws {
        guard ProcessInfo.processInfo.environment["KNOCK_RUN_DUAL_DEVICE_UAT"] == "1" else {
            throw XCTSkip("Opt-in dual-device convergence UAT is disabled")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Dual-device convergence UAT requires a physical iPhone")
        #else
        let expected = try await UITestFixtureClient().latestSessionExpectation()
        let app = launchForIsolatedFixture(suppressKnockOverlay: true)
        signInIfNeeded(app)
        dismissKnockIfPresent(app)

        let menu = app.buttons["drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()

        let sessions = app.buttons["drawer.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 15))
        sessions.tap()

        // The directory intentionally prioritizes needs-user decisions over
        // queued/running sessions. A newly updated session can therefore be
        // outside the initial LazyVStack viewport, and titles are not unique.
        // Filter by the backend-owned opaque id before asserting the title so
        // this UAT verifies the exact session rather than a visible namesake.
        let search = app.textFields["inbox.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText(expected.id)

        let expectedTitle = app.staticTexts[expected.title]
        XCTAssertTrue(
            expectedTitle.waitForExistence(timeout: 30),
            "The latest backend-owned session must converge to this device. session_id=\(expected.id)"
        )
        print("[dual-device-uat] session_id=\(expected.id) title=\(expected.title)")
        attachScreenshot(app, named: "dual-device-convergence-\(expected.id)")
        #endif
    }

    func testPhysicalCacheSurvivesAirplaneModeAndRecovers() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KNOCK_RUN_AIRPLANE_MODE_UAT"] == "1" else {
            throw XCTSkip("Opt-in physical airplane-mode UAT is disabled")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Airplane-mode cache and recovery UAT requires a physical iPhone")
        #else
        let phase = environment["KNOCK_AIRPLANE_PHASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let expectedTitle = environment["KNOCK_AIRPLANE_EXPECTED_SESSION_TITLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ["seed", "offline", "transition-offline", "recovered"].contains(phase) else {
            XCTFail("KNOCK_AIRPLANE_PHASE must be seed, offline, transition-offline, or recovered")
            return
        }
        guard !expectedTitle.isEmpty else {
            XCTFail("KNOCK_AIRPLANE_EXPECTED_SESSION_TITLE is required")
            return
        }

        var preparedSessionID: String?
        if phase == "seed" || phase == "transition-offline" || phase == "recovered" {
            preparedSessionID = try await UITestFixtureClient()
                .prepareNeedsUserFixture(title: expectedTitle)
            print("[airplane-uat] prepared_session_id=\(preparedSessionID ?? "missing")")
        }

        let app = phase == "seed"
            ? launchForIsolatedFixture(suppressKnockOverlay: true)
            : launchPreservingPhysicalState()

        if phase == "seed" {
            signInIfNeeded(app)
        } else {
            let drawer = app.buttons["drawer.open"]
            guard drawer.waitForExistence(timeout: 30) else {
                attachScreenshot(app, named: "airplane-\(phase)-authentication-missing")
                XCTFail("The authenticated workspace and its SQLite cache must survive the \(phase) relaunch.")
                return
            }
        }
        dismissKnockIfPresent(app)

        if phase == "offline" {
            let offlineRetry = app.buttons["home.connection.retry"]
            guard offlineRetry.waitForExistence(timeout: 30) else {
                attachScreenshot(app, named: "airplane-offline-state-missing")
                XCTFail("The device must visibly report an unavailable route. Verify that airplane mode is on and Wi-Fi is also off.")
                return
            }
            attachScreenshot(app, named: "airplane-offline-state")
        }

        if phase == "transition-offline" {
            let baselineMenu = app.buttons["drawer.open"]
            XCTAssertTrue(baselineMenu.waitForExistence(timeout: 30))
            baselineMenu.tap()
            let baselineSessions = app.buttons["drawer.sessions"]
            XCTAssertTrue(baselineSessions.waitForExistence(timeout: 15))
            baselineSessions.tap()
            try await refreshInboxAndWait(app)
            selectAllAgentsIfAvailable(app, required: true)
            let baselineSearch = app.textFields["inbox.search"]
            XCTAssertTrue(baselineSearch.waitForExistence(timeout: 15))
            baselineSearch.tap()
            baselineSearch.typeText(expectedTitle)
            XCTAssertTrue(app.staticTexts[expectedTitle].waitForExistence(timeout: 30))
            attachScreenshot(app, named: "airplane-transition-online-baseline")

            let countdown = max(
                15,
                Int(environment["KNOCK_AIRPLANE_COUNTDOWN_SECONDS"] ?? "") ?? 30
            )
            print("[airplane-uat] ready_for_airplane_mode countdown=\(countdown)")
            for seconds in stride(from: countdown, through: 1, by: -1) {
                if seconds == countdown || seconds <= 5 || seconds.isMultiple(of: 5) {
                    print("[airplane-uat] enable_airplane_mode seconds_remaining=\(seconds)")
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            app.terminate()
            if environment["KNOCK_FORCE_UNREACHABLE_ROUTE_UAT"] == "1" {
                let unreachableURL = "http://127.0.0.1:9"
                app.launchEnvironment["KNOCK_UI_TEST_API_BASE_URL"] = unreachableURL
                app.launchEnvironment["KNOCK_API_BASE_URL"] = unreachableURL
                print("[airplane-uat] using_controlled_unreachable_route=1")
            }
            app.launch()
            let cachedWorkspace = app.buttons["drawer.open"]
            guard cachedWorkspace.waitForExistence(timeout: 30) else {
                attachScreenshot(app, named: "airplane-transition-authentication-missing")
                XCTFail("The authenticated workspace must relaunch from local state after airplane mode is enabled.")
                return
            }
            let offlineRetry = app.buttons["home.connection.retry"]
            guard offlineRetry.waitForExistence(timeout: 30) else {
                attachScreenshot(app, named: "airplane-transition-offline-state-missing")
                XCTFail("The device must visibly report an unavailable route. Verify that airplane mode is on and Wi-Fi is also off.")
                return
            }
            attachScreenshot(app, named: "airplane-transition-offline-state")
            dismissKnockIfPresent(app)
        }

        let menu = app.buttons["drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()

        let sessions = app.buttons["drawer.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 15))
        sessions.tap()
        selectAllAgentsIfAvailable(app)

        let search = app.textFields["inbox.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText(expectedTitle)

        let timeout: TimeInterval = ["offline", "transition-offline"].contains(phase) ? 15 : 45
        let expected = app.staticTexts[expectedTitle]
        XCTAssertTrue(
            expected.waitForExistence(timeout: timeout),
            "The expected session must be visible during the \(phase) phase."
        )
        print("[airplane-uat] phase=\(phase) title=\(expectedTitle)")
        attachScreenshot(app, named: "airplane-\(phase)-cache")
        #endif
    }

    private func selectAllAgentsIfAvailable(
        _ app: XCUIApplication,
        required: Bool = false
    ) {
        let agentFilter = app.buttons["agent.filter"]
        guard agentFilter.waitForExistence(timeout: required ? 20 : 5) else {
            if required {
                XCTFail("Refresh must load every agent before the offline baseline is cached.")
            }
            return
        }
        agentFilter.tap()
        let allAgents = app.buttons["All agents"]
        XCTAssertTrue(allAgents.waitForExistence(timeout: 5))
        allAgents.tap()
    }

    private func refreshInboxAndWait(_ app: XCUIApplication) async throws {
        let refresh = app.buttons["inbox.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        refresh.tap()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let completed = expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: refresh
        )
        await fulfillment(of: [completed], timeout: 45)
    }

    private func waitForVoiceDockStatus(
        _ dock: XCUIElement,
        timeout: TimeInterval,
        matching predicate: (String) -> Bool
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = (dock.value as? String) ?? "Unknown"
            if predicate(status) { return status }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let finalStatus = (dock.value as? String) ?? "Unknown"
        return predicate(finalStatus) ? finalStatus : nil
    }

    private func waitForCommandDelta(
        fixture: UITestFixtureClient,
        baseline: Set<String>,
        minimumCount: Int,
        timeout: TimeInterval = 30
    ) async throws -> (all: Set<String>, new: Set<String>) {
        let deadline = Date().addingTimeInterval(timeout)
        var all = baseline
        repeat {
            all = try await fixture.commandIDs()
            let new = all.subtracting(baseline)
            if new.count >= minimumCount { return (all, new) }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        return (all, all.subtracting(baseline))
    }

    private func waitForCommandState(
        fixture: UITestFixtureClient,
        commandID: String,
        expectedState: String,
        timeout: TimeInterval = 30
    ) async throws -> UITestFixtureClient.CommandDetail {
        let deadline = Date().addingTimeInterval(timeout)
        var detail = try await fixture.commandDetail(commandID: commandID)
        while detail.state != expectedState && Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            detail = try await fixture.commandDetail(commandID: commandID)
        }
        return detail
    }

    private func commandSetRemainsUnchanged(
        fixture: UITestFixtureClient,
        expected: Set<String>,
        duration: TimeInterval,
        pollingInterval: UInt64 = 500_000_000
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while true {
            guard try await fixture.commandIDs() == expected else { return false }
            if Date() >= deadline { return true }
            try await Task.sleep(nanoseconds: pollingInterval)
        }
    }

    private func requireStableHighRiskConfirmation(
        fixture: UITestFixtureClient,
        initial: UITestFixtureClient.CommandDetail,
        expectedCommandIDs: Set<String>,
        duration: TimeInterval = 10
    ) async throws -> UITestFixtureClient.CommandDetail {
        let deadline = Date().addingTimeInterval(duration)
        var latest = initial
        while true {
            latest = try await fixture.commandDetail(commandID: initial.commandID)
            guard latest.state == "awaiting_confirmation",
                  latest.intent == "send_message",
                  latest.riskLevel == "high",
                  latest.needsConfirmation,
                  !latest.hasNonNullResult,
                  latest.idempotencyKey == initial.idempotencyKey,
                  latest.canonicalEnvelope == initial.canonicalEnvelope else {
                throw UITestFixtureError(
                    message: "High-risk command did not remain safely awaiting confirmation"
                )
            }
            guard try await fixture.commandIDs() == expectedCommandIDs else {
                throw UITestFixtureError(
                    message: "High-risk confirmation window changed the backend command set"
                )
            }
            if Date() >= deadline { return latest }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func testPhysicalVoiceProductionPath() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KNOCK_RUN_PHYSICAL_VOICE_E2E"] == "1" else {
            throw XCTSkip("Opt-in physical voice UAT is disabled")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical microphone, on-device voice, and TTS UAT requires an iPhone")
        #else
        let manualCaptureValue = environment["KNOCK_PHYSICAL_VOICE_MANUAL_CAPTURE"] ?? "0"
        guard ["0", "1"].contains(manualCaptureValue) else {
            XCTFail("KNOCK_PHYSICAL_VOICE_MANUAL_CAPTURE must be 0 or 1")
            return
        }
        let captureMode: PhysicalVoiceCaptureMode = manualCaptureValue == "1"
            ? .manual
            : .automated
        let expectationValue = environment["KNOCK_PHYSICAL_VOICE_EXPECTATION_MODE"]
            ?? environment["KNOCK_PHYSICAL_VOICE_EXPECTATION"]
            ?? "history"
        guard let expectationMode = PhysicalVoiceExpectationMode(rawValue: expectationValue) else {
            XCTFail(
                "KNOCK_PHYSICAL_VOICE_EXPECTATION_MODE must be history, high-risk, or clarification"
            )
            return
        }

        let configuredBaseURL = UITestFixtureClient.configuredBaseURLString(environment: environment)
        guard UITestFixtureClient.isApprovedPhysicalVoiceBaseURL(configuredBaseURL) else {
            XCTFail(
                "Physical voice UAT requires the exact staging origin or an RFC1918 HTTP origin; "
                    + "configured value redacted"
            )
            return
        }

        let fixture = try UITestFixtureClient()
        if expectationMode == .highRisk {
            try await fixture.requireActionProviderDisabled()
        }
        try await fixture.prepareAccount()
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

        let expectedRuntime = environment["KNOCK_EXPECTED_VOICE_RUNTIME"] ?? "signed-gemma"
        let expectedStrategyLabel: String
        let readyPredicate: NSPredicate
        switch expectedRuntime {
        case "signed-gemma":
            expectedStrategyLabel = "Runtime policy · Signed Gemma"
            readyPredicate = NSPredicate(
                format: "identifier == %@ AND label BEGINSWITH %@ AND NOT label CONTAINS %@",
                "settings.voice.status",
                "Ready · Gemma",
                "Update failed"
            )
        case "safe-parser":
            expectedStrategyLabel = "Runtime policy · Safe parser"
            readyPredicate = NSPredicate(
                format: "identifier == %@ AND label == %@",
                "settings.voice.status",
                "Ready · Safe parser"
            )
        default:
            XCTFail("Unsupported KNOCK_EXPECTED_VOICE_RUNTIME: \(expectedRuntime)")
            return
        }
        let strategy = app.staticTexts["settings.voice.strategy"]
        XCTAssertTrue(strategy.waitForExistence(timeout: 10))
        XCTAssertEqual(strategy.label, expectedStrategyLabel)
        let ready = app.staticTexts.matching(readyPredicate).firstMatch
        let prepareOrRefresh = app.buttons["settings.voice.prepare"]
        XCTAssertTrue(
            prepareOrRefresh.waitForExistence(timeout: 10),
            "The Voice settings panel must expose model preparation."
        )
        prepareOrRefresh.tap()
        let preparing = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Preparing")
        ).firstMatch
        if expectedRuntime == "signed-gemma" {
            _ = preparing.waitForExistence(timeout: 15)
        }
        XCTAssertTrue(
            ready.waitForExistence(timeout: 240),
            "The device must prepare the explicitly selected \(expectedRuntime) runtime."
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

        // Microphone and Speech Recognition permissions are a hard UAT
        // precondition. Never press the production dock merely to prime them:
        // any press can process speech and submit a command. Capture the
        // backend baseline before the first and only measured interaction.
        let baselineCommandIDs = try await fixture.commandIDs()
        print(
            "[physical-voice-uat] expectation=\(expectationMode.rawValue); "
                + "permissions=pre-granted"
        )

        switch captureMode {
        case .automated:
            let configuredCountdown = Int(
                environment["KNOCK_PHYSICAL_VOICE_COUNTDOWN_SECONDS"] ?? "5"
            ) ?? 5
            let countdown = min(max(configuredCountdown, 3), 30)
            let configuredHold = Double(
                environment["KNOCK_PHYSICAL_VOICE_HOLD_SECONDS"] ?? "12"
            ) ?? 12
            let holdSeconds = min(max(configuredHold, 8), 20)
            print(
                "[physical-voice-uat] WATCH PHONE in \(countdown)s; "
                    + "speak only after Listening appears (hold=\(holdSeconds)s)"
            )
            try await Task.sleep(nanoseconds: UInt64(countdown) * 1_000_000_000)
            dock.press(forDuration: holdSeconds)
        case .manual:
            print(
                "[physical-voice-uat] MANUAL: press and hold voice.dock now; "
                    + "wait for Listening, say the exact phrase, then release after silence."
            )
            guard try await waitForVoiceDockStatus(
                dock,
                timeout: 120,
                matching: { $0 == "Listening" }
            ) != nil else {
                attachScreenshot(app, named: "physical-voice-manual-listening-timeout")
                XCTFail("Manual capture did not reach Listening within 120 seconds")
                return
            }
            print("[physical-voice-uat] MANUAL: Listening detected; release after speaking.")
            guard try await waitForVoiceDockStatus(
                dock,
                timeout: 120,
                matching: { $0 != "Listening" }
            ) != nil else {
                attachScreenshot(app, named: "physical-voice-manual-release-timeout")
                XCTFail("Manual capture was not released within 120 seconds")
                return
            }
        }
        attachScreenshot(app, named: "physical-voice-after-capture")

        switch expectationMode {
        case .history:
            let terminal = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == %@ AND label CONTAINS %@",
                    "voice.command.presentation",
                    "History search completed. Review the results on screen."
                )
            ).firstMatch
            let resultDeadline = Date().addingTimeInterval(120)
            var captureStatus = (dock.value as? String) ?? "Unknown"
            while Date() < resultDeadline && !terminal.exists {
                captureStatus = (dock.value as? String) ?? "Unknown"
                if captureStatus == "Needs clarification" || captureStatus.hasPrefix("Failed") {
                    break
                }
                let later = app.buttons["knock.later"]
                if later.exists {
                    later.tap()
                    _ = later.waitForNonExistence(timeout: 5)
                    continue
                }
                _ = terminal.waitForExistence(timeout: 2)
            }
            guard terminal.exists else {
                attachScreenshot(app, named: "physical-voice-history-failed")
                XCTFail(
                    "History UAT requires the backend-owned completed presentation. "
                        + "Capture status: \(captureStatus)."
                )
                return
            }

            let snapshot = try await waitForCommandDelta(
                fixture: fixture,
                baseline: baselineCommandIDs,
                minimumCount: 1
            )
            guard snapshot.new.count == 1, let commandID = snapshot.new.first else {
                XCTFail("History UAT must create exactly one backend command")
                return
            }
            let original = try await fixture.commandDetail(commandID: commandID)
            guard original.intent == "search_history",
                  original.state == "succeeded",
                  original.riskLevel == "low",
                  !original.needsConfirmation,
                  original.version != nil else {
                XCTFail("History UAT command must durably succeed as search_history")
                return
            }
            let replayed = try await fixture.replayCanonicalCommandForRowProof(original)
            let persistedAfterReplay = try await fixture.commandDetail(commandID: commandID)
            XCTAssertEqual(replayed.commandID, original.commandID)
            XCTAssertTrue(
                replayed.idempotencyKey == original.idempotencyKey,
                "Canonical row replay must preserve the server idempotency key"
            )
            XCTAssertTrue(
                replayed.canonicalEnvelope == original.canonicalEnvelope,
                "Canonical row replay must return the same canonical server envelope"
            )
            XCTAssertEqual(replayed.state, original.state)
            XCTAssertEqual(replayed.version, original.version)
            XCTAssertTrue(
                replayed.canonicalResult == original.canonicalResult,
                "Canonical row replay must preserve the redacted result snapshot"
            )
            XCTAssertEqual(persistedAfterReplay.state, original.state)
            XCTAssertEqual(persistedAfterReplay.version, original.version)
            XCTAssertTrue(
                persistedAfterReplay.canonicalEnvelope == original.canonicalEnvelope,
                "The durable command must preserve its canonical envelope after replay"
            )
            XCTAssertTrue(
                persistedAfterReplay.canonicalResult == original.canonicalResult,
                "The durable command must preserve its redacted result after replay"
            )
            let replayKeptOneCommand = try await commandSetRemainsUnchanged(
                fixture: fixture,
                expected: snapshot.all,
                duration: 5
            )
            XCTAssertTrue(
                replayKeptOneCommand,
                "Canonical row replay must not create an additional backend command"
            )
            attachScreenshot(app, named: "physical-voice-backend-result")
            print("[physical-voice-uat] Human must confirm that TTS said: History search completed.")
            print(
                "[physical-voice-uat] Row proof only: one durable command and a stable canonical "
                    + "response. App cold-start envelope replay is covered by "
                    + "BackendCommandPresentationTests.testColdStartSubmitting404ReplaysExactEnvelope; "
                    + "provider effect dedupe is covered by the backend provider lifecycle gate."
            )

        case .highRisk:
            let confirmationSheet = app.descendants(matching: .any)["command.confirmationSheet"]
            let resultDeadline = Date().addingTimeInterval(120)
            var captureStatus = (dock.value as? String) ?? "Unknown"
            while Date() < resultDeadline && !confirmationSheet.exists {
                captureStatus = (dock.value as? String) ?? "Unknown"
                if captureStatus == "Needs clarification" || captureStatus.hasPrefix("Failed") {
                    break
                }
                _ = confirmationSheet.waitForExistence(timeout: 2)
            }
            guard confirmationSheet.exists else {
                attachScreenshot(app, named: "physical-voice-high-risk-sheet-missing")
                XCTFail(
                    "High-risk UAT must show command.confirmationSheet without confirming. "
                        + "Capture status: \(captureStatus)."
                )
                return
            }
            attachScreenshot(app, named: "physical-voice-high-risk-confirmation")

            let snapshot = try await waitForCommandDelta(
                fixture: fixture,
                baseline: baselineCommandIDs,
                minimumCount: 1
            )
            guard snapshot.new.count == 1, let commandID = snapshot.new.first else {
                XCTFail("High-risk UAT must create exactly one backend command")
                return
            }
            let detail = try await fixture.commandDetail(commandID: commandID)
            guard detail.intent == "send_message",
                  detail.state == "awaiting_confirmation",
                  detail.riskLevel == "high",
                  detail.needsConfirmation,
                  !detail.hasNonNullResult else {
                XCTFail(
                    "High-risk UAT requires a high-risk, confirmation-required command with no result"
                )
                return
            }
            _ = try await requireStableHighRiskConfirmation(
                fixture: fixture,
                initial: detail,
                expectedCommandIDs: snapshot.all,
                duration: 10
            )
            guard confirmationSheet.exists else {
                XCTFail("High-risk confirmation UI disappeared before safe cancellation")
                return
            }

            let cancel = app.buttons["command.cancel"]
            guard cancel.waitForExistence(timeout: 10), cancel.isHittable else {
                XCTFail("High-risk UAT could not safely cancel the unconfirmed command")
                return
            }
            cancel.tap()
            XCTAssertTrue(
                confirmationSheet.waitForNonExistence(timeout: 30),
                "Safe cancellation must dismiss the confirmation sheet"
            )
            let cancelled = try await waitForCommandState(
                fixture: fixture,
                commandID: commandID,
                expectedState: "cancelled"
            )
            XCTAssertEqual(cancelled.state, "cancelled")
            XCTAssertEqual(cancelled.riskLevel, "high")
            XCTAssertTrue(cancelled.needsConfirmation)
            XCTAssertFalse(
                cancelled.hasNonNullResult,
                "Safe cancellation must not produce an external-effect result"
            )
            let cancellationKeptOneCommand = try await commandSetRemainsUnchanged(
                fixture: fixture,
                expected: snapshot.all,
                duration: 5
            )
            XCTAssertTrue(
                cancellationKeptOneCommand,
                "Cancelling must not create an additional backend command"
            )
            let cancelledAfterWindow = try await fixture.commandDetail(commandID: commandID)
            XCTAssertEqual(cancelledAfterWindow.state, "cancelled")
            XCTAssertFalse(
                cancelledAfterWindow.hasNonNullResult,
                "The cancelled command must remain without an external-effect result"
            )
            print(
                "[physical-voice-uat] Provider effects were disabled before capture; the high-risk "
                    + "command stayed awaiting_confirmation for 10 seconds, was never confirmed, "
                    + "and was cancelled safely."
            )

        case .clarification:
            guard try await waitForVoiceDockStatus(
                dock,
                timeout: 120,
                matching: { $0 == "Needs clarification" }
            ) != nil else {
                attachScreenshot(app, named: "physical-voice-clarification-missing")
                XCTFail("Clarification UAT must reach Needs clarification")
                return
            }
            let clarificationCreatedNoCommand = try await commandSetRemainsUnchanged(
                fixture: fixture,
                expected: baselineCommandIDs,
                duration: 30
            )
            XCTAssertTrue(
                clarificationCreatedNoCommand,
                "Clarification must sustain zero backend command delta for 30 seconds"
            )
            attachScreenshot(app, named: "physical-voice-clarification")
            print(
                "[physical-voice-uat] Clarification sustained zero backend command delta for 30 seconds."
            )
        }
        #endif
    }
}
