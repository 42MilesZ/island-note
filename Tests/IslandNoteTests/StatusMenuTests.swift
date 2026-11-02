import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class StatusMenuTests: XCTestCase {
    func testStandardMenuCommandsInBothLanguages() throws {
        _ = NSApplication.shared
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.english, .chinese] {
            L10n.language = language
            var opened = 0
            var settingsOpened = 0
            let controller = StatusMenuController(onOpen: { opened += 1 }, onSettings: { settingsOpened += 1 })
            let menu = controller.makeMenu()
            menu.update()
            XCTAssertEqual(menu.items.count, 4)
            XCTAssertEqual(menu.items[0].title, language == .chinese ? "打开 Island Note" : "Open Island Note")
            menu.performActionForItem(at: 0)
            menu.performActionForItem(at: 1)
            XCTAssertEqual(opened, 1)
            XCTAssertEqual(settingsOpened, 1)
            XCTAssertTrue(menu.items[2].isSeparatorItem)
            let quit = menu.items[3]
            XCTAssertEqual(quit.title, language == .chinese ? "退出 Island Note" : "Quit Island Note")
            XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
            XCTAssertTrue(quit.target === NSApp)
            XCTAssertEqual(quit.keyEquivalent, "q")
            XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])
            XCTAssertTrue(quit.isEnabled)
        }
    }
}
