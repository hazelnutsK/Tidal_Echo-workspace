import XCTest

final class VoiceRecordingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// 2026-10-25: on the Telegram bar the recording strip's X did nothing.
    func testTelegramRecordingStripCancels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--imessage-ui-review", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["REVIEW_COMPOSER"] = "telegram"
        app.launch()

        let mic = app.buttons["录语音"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.tap()
        let cancel = app.buttons["取消录音"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "recording strip never appeared")
        // A fingertip, not a stylus: land 12pt left of the glyph's center.
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: -12, dy: 0))
            .tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3), "X did not close the recording strip")
        XCTAssertTrue(app.buttons["录语音"].exists)
    }
}
