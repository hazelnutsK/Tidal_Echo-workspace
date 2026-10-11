import XCTest

final class IMessageLayoutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(theme: String = "mist", classic: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--imessage-ui-review", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["REVIEW_THEME"] = theme
        app.launchEnvironment["REVIEW_CLASSIC"] = classic ? "1" : "0"
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReferenceProportionsAndComposerStates() throws {
        let app = launch()
        let avatar = app.buttons["chat.sessionAvatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 15))
        let add = app.buttons["chat.add"]
        let action = app.buttons["chat.composerAction"]
        let width = app.frame.width
        XCTAssertEqual(avatar.frame.width / width, 90.0 / 591, accuracy: 0.005)
        XCTAssertEqual(avatar.frame.midX, width / 2, accuracy: 1)
        XCTAssertEqual(add.frame.width / width, 60.0 / 591, accuracy: 0.005)
        XCTAssertEqual(add.frame.minX / width, 42.0 / 591, accuracy: 0.005)
        XCTAssertLessThan(app.buttons["设置"].frame.width, avatar.frame.width * 0.8)
        XCTAssertEqual(action.label, "录语音")
        capture("01-idle-reference-proportions")

        let draft = app.textViews["chat.draft"].exists
            ? app.textViews["chat.draft"] : app.textFields["chat.draft"]
        XCTAssertTrue(draft.exists)
        XCTAssertLessThanOrEqual(draft.frame.height, add.frame.height + 2)
        draft.tap()
        // A numeric draft avoids system autocorrection appending/replacing words
        // while this test verifies the empty/nonempty action transition.
        draft.typeText("1234567890")
        XCTAssertEqual(action.label, "发送消息")
        capture("02-keyboard-send-button")
        draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        XCTAssertEqual(action.label, "录语音")
        draft.typeText("One line\nTwo lines\nThree lines\nFour lines")
        XCTAssertGreaterThan(draft.frame.height, add.frame.height)
        capture("03-multiline-keyboard")
    }

    func testMenuAttachmentsFacesAndAvatar() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["chat.add"].waitForExistence(timeout: 15))
        app.buttons["chat.add"].tap()
        XCTAssertTrue(app.buttons["添加附件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["表情包"].exists)
        capture("04-plus-menu")
        app.buttons["添加附件"].tap()
        XCTAssertTrue(app.buttons["照片"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["文件"].exists)
        capture("05-attachment-choices")
        // iOS 26 presents this as a popover; tap the conversation to dismiss.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        app.buttons["chat.add"].tap()
        app.buttons["表情包"].tap()
        XCTAssertTrue(app.staticTexts["颜文字"].waitForExistence(timeout: 5))
        capture("06-faces-drawer")
        app.terminate()

        let next = launch()
        XCTAssertTrue(next.buttons["chat.sessionAvatar"].waitForExistence(timeout: 15))
        next.buttons["chat.sessionAvatar"].tap()
        XCTAssertTrue(next.navigationBars["对话窗口"].waitForExistence(timeout: 5))
        capture("07-avatar-window-switcher")
    }

    func testThemeAndClassicScreenshots() throws {
        for theme in ["harbor", "paper", "nest"] {
            let app = launch(theme: theme)
            XCTAssertTrue(app.buttons["chat.sessionAvatar"].waitForExistence(timeout: 15))
            capture("08-theme-\(theme)")
            app.terminate()
        }
        let classic = launch(classic: true)
        XCTAssertTrue(classic.buttons["face.smiling"].waitForExistence(timeout: 10)
                      || classic.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(classic.buttons["chat.sessionAvatar"].exists)
        capture("09-classic-layout")
    }
}
