import XCTest

final class VoiceAgentBridgeUITests: XCTestCase {
    private func signInIfNeeded(_ app: XCUIApplication) {
        let login = app.buttons["login.submit"]
        if login.waitForExistence(timeout: 5) {
            // Registration is now explicit. The Debug build supplies the
            // local fixture email/password; switch from the sign-in mode so
            // a clean simulator can create that fixture account once.
            let modeToggle = app.buttons["login.modeToggle"]
            if modeToggle.waitForExistence(timeout: 3) {
                modeToggle.tap()
            }
            login.tap()
        }
    }

    private func dismissKnockIfPresent(_ app: XCUIApplication) {
        let later = app.buttons["knock.later"]
        if later.waitForExistence(timeout: 5) {
            later.tap()
        }
    }

    func testDecisionSurfaceCompletesDestructiveConfirmationFlow() {
        let app = XCUIApplication()
        app.launch()

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

    func testSettingsGeneratesAndCopiesPairingCode() {
        let app = XCUIApplication()
        app.launch()
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

    func testDashboardSearchAndFiltersStayUsable() {
        let app = XCUIApplication()
        app.launch()
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
