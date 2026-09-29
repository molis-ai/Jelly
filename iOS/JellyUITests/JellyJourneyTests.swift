import XCTest

/// Runs against the normal app and its simulator sandbox, without seeding or
/// bypassing production commands. Unique titles preserve previous test data.
@MainActor
final class JellyJourneyTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCalendarNotesAndInspirationSurviveRelaunch() throws {
        let suffix = String(UUID().uuidString.prefix(8))
        let taskTitle = "Weekend reading \(suffix)"
        let noteTitle = "Reading notes \(suffix)"
        let noteBody = "Read one chapter and write down three useful ideas."
        let inspiration = "Try a quiet reading hour after breakfast. \(suffix)"

        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        tap(app.buttons["add-calendar-item"])
        let title = app.descendants(matching: .any)["item-title"].firstMatch
        tap(title)
        title.typeText(taskTitle)
        tap(app.buttons["save-calendar-item"])
        tap(app.segmentedControls.buttons["日程"])
        tap(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", taskTitle)).firstMatch)
        tap(completion("标记完成"))
        XCTAssertTrue(completion("已完成 · 重新打开").waitForExistence(timeout: 10))
        capture("01-calendar-completed")
        tap(app.buttons["save-calendar-item"])

        tap(app.tabBars.buttons["笔记"])
        tap(app.buttons["新建笔记"])
        let noteTitleField = app.textViews["笔记标题"]
        tap(noteTitleField)
        noteTitleField.typeText(noteTitle)
        let body = app.textViews["笔记正文，支持连续选择与编辑"]
        tap(body)
        body.typeText(noteBody)
        tap(app.buttons["返回"])
        tap(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", noteTitle)).firstMatch)
        XCTAssertEqual(noteTitleField.value as? String, noteTitle)
        XCTAssertTrue((body.value as? String)?.contains(noteBody) == true)
        capture("02-note-reopened")
        tap(app.buttons["返回"])

        tap(app.tabBars.buttons["灵感"])
        tap(app.buttons["收下灵感"])
        let captureField = app.textViews["输入灵感文字或链接"]
        tap(captureField)
        captureField.typeText(inspiration)
        tap(app.buttons["保存"])
        tap(app.buttons["继续写成笔记"])
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue((body.value as? String)?.contains(inspiration) == true)
        capture("03-inspiration-converted")
        tap(app.buttons["返回"])

        // End the process and start it again: in-memory success is insufficient.
        app.terminate()
        app.launch()
        tap(app.segmentedControls.buttons["日程"])
        tap(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", taskTitle)).firstMatch)
        XCTAssertTrue(completion("已完成 · 重新打开").waitForExistence(timeout: 10))
        tap(completion("已完成 · 重新打开"))
        XCTAssertTrue(completion("标记完成").waitForExistence(timeout: 10))
        tap(app.buttons["save-calendar-item"])
        tap(app.tabBars.buttons["笔记"])
        tap(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", noteTitle)).firstMatch)
        XCTAssertEqual(noteTitleField.value as? String, noteTitle)
        XCTAssertTrue((body.value as? String)?.contains(noteBody) == true)
        tap(app.buttons["返回"])
        tap(app.tabBars.buttons["灵感"])
        tap(app.segmentedControls.buttons["已成笔记"])
        tap(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", suffix)).firstMatch)
        XCTAssertTrue(app.buttons["打开笔记"].waitForExistence(timeout: 10))
        capture("04-inspiration-after-relaunch")
    }

    private func completion(_ label: String) -> XCUIElement {
        app.buttons.matching(identifier: "calendar-completion")
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing element: \(element)\n\(app.debugDescription)", file: file, line: line)
        element.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
