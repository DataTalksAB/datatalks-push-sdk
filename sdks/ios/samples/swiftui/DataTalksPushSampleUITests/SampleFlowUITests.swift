import XCTest

/// Real notifications on a simulator, delivered by `xcrun simctl push` while this runs (see `sdks/ios/README.md`). Skipped without the
/// app key in the environment.
final class SampleFlowUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testIdentifyConsentLogout() throws {
        let app = try launchedApp()

        app.textFields["Email"].tap()
        app.textFields["Email"].typeText("anna@example.com")
        app.buttons["Identify"].tap()
        scrollDown(app)
        let accepted = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Identify accepted'")).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 30), "The identify should be answered.")

        let toggle = app.switches["Marketing pushes"]
        if toggle.isHittable { toggle.switches.firstMatch.tap() }
        app.buttons["Log out"].tap()
    }

    func testPermissionForegroundMessageAndTap() throws {
        let app = try launchedApp()

        app.buttons["Ask for permission"].tap()
        // Only the first run on a simulator asks.
        let allow = springboard.alerts.firstMatch.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }

        let message = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Message '")).firstMatch
        scrollDown(app)
        XCTAssertTrue(message.waitForExistence(timeout: 60), "A push should reach the listener while the app is open.")

        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Match day'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "A push should show while the app is away.")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "A tap should open the app.")
        scrollDown(app)
        let opened = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Opened: '")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 15), "A tap should reach onNotificationOpened.")
        XCTAssertTrue(opened.label.contains("T-1042"), opened.label)
    }

    // Runs after the test that grants the permission. The app isn't running at the tap, and the link uses the app's own scheme.
    func testTapThatStartsTheAppOpensItsLink() throws {
        let app = try launchedApp()
        app.terminate()

        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Link day'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "A push should show while the app is closed.")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "A tap should start the app.")
        scrollDown(app)
        let opened = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Opened: dtpushsample://'")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 15), "A tap should reach onNotificationOpened.")
        let link = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Link: dtpushsample://'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "A tap should open the app's own link.")
    }

    // Named to run last, so the ingress ends with the install deleted.
    func testZDeleteLocalData() throws {
        let app = try launchedApp()

        app.swipeUp()
        app.buttons["Delete local data"].tap()
        Thread.sleep(forTimeInterval: 3)
    }

    private func launchedApp() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let appKey = environment["SAMPLE_APP_KEY"], let baseUrl = environment["SAMPLE_BASE_URL"], let token = environment["SAMPLE_TEST_TOKEN"] else {
            throw XCTSkip("Needs TEST_RUNNER_SAMPLE_APP_KEY, TEST_RUNNER_SAMPLE_BASE_URL and TEST_RUNNER_SAMPLE_TEST_TOKEN.")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-appKey", appKey, "-baseUrl", baseUrl, "-testToken", token]
        app.launch()
        return app
    }

    private func scrollDown(_ app: XCUIApplication) {
        app.swipeUp()
        app.swipeUp()
    }
}
