import XCTest

final class GlassyRecordUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    func testHomeScreenShowsRecordButton() {
        XCTAssertTrue(app.navigationBars["Glassy Record"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Начать запись"].exists)
    }

    func testNavigateToSettings() {
        app.buttons["Настройки"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Очки Monokol MK295"].exists)
    }

    func testGlassesCardToggle() {
        let toggle = app.switches.element(boundBy: 0)
        if toggle.exists {
            toggle.tap()
        }
    }

    func testQualityChipsVisible() {
        XCTAssertTrue(app.buttons["1080p"].exists)
        XCTAssertTrue(app.buttons["4K"].exists)
    }
}
