import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class TextShortcutTests: XCTestCase {
    private var panel: IslandPanel!
    private var text: NSTextView!

    override func setUp() async throws {
        _ = NSApplication.shared
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        panel.contentView?.addSubview(text)
        text.string = "first line\nsecond line"
        XCTAssertTrue(panel.makeFirstResponder(text))
    }

    override func tearDown() async throws {
        panel.close()
        panel = nil
        text = nil
    }

    /// Mirrors AppKit's dispatch: key equivalents first, then keyDown to the first responder.
    private func press(_ key: Int, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        let character = String(UnicodeScalar(UInt32(key))!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.function),
                                     timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                     characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: keyCode)!
        if panel.performKeyEquivalent(with: event) { return false }
        text.keyDown(with: event)
        return true
    }

    func testCommandArrowsMoveAndExtendTheSelection() {
        text.setSelectedRange(NSRange(location: 14, length: 0))
        XCTAssertTrue(press(NSRightArrowFunctionKey, keyCode: 124, .command))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 22, length: 0))
        XCTAssertTrue(press(NSLeftArrowFunctionKey, keyCode: 123, .command))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 11, length: 0))
        XCTAssertTrue(press(NSDownArrowFunctionKey, keyCode: 125, [.command, .shift]))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 11, length: 11))
        XCTAssertTrue(press(NSUpArrowFunctionKey, keyCode: 126, .command))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testCommandDeleteRemovesToLineStart() {
        text.setSelectedRange(NSRange(location: 17, length: 0))
        XCTAssertTrue(press(NSDeleteCharacter, keyCode: 51, .command))
        XCTAssertEqual(text.string, "first line\n line")
    }

    func testUnboundCommandLettersAreStillSwallowed() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: panel.windowNumber, context: nil, characters: "k",
                                     charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        XCTAssertTrue(panel.performKeyEquivalent(with: event))
    }
}
