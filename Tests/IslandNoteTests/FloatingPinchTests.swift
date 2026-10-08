import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class FloatingPinchTests: XCTestCase {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.compactMap { find(type, in: $0) }.first
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.1)) }

    func testFloatingPinchImmediatelyAfterReleasePreservesEditingAndDocking() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-floating-pinch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("fixture.md")
        let source = "# Header\n\nA body paragraph that stays intact while the panel changes size.\n"
        try source.write(to: note, atomically: true, encoding: .utf8)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let controller = IslandNoteController(store: NoteStore(fileURL: note), enableSync: false)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? IslandPanel }.first {
            !existing.contains(ObjectIdentifier($0))
        })
        defer { panel.close() }
        controller.expand()
        settle()
        let editor = try XCTUnwrap(find(NoteEditorView.self, in: try XCTUnwrap(panel.contentView)))
        let text = try XCTUnwrap(find(NSTextView.self, in: editor))
        text.setSelectedRange(NSRange(location: 10, length: 5))
        let selection = text.selectedRange()
        let font = try XCTUnwrap(text.textStorage?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)
        let home = panel.frame.origin
        let originalFrame = editor.frame
        let start = NSPoint(x: home.x + originalFrame.midX, y: home.y + originalFrame.maxY - PanelDocking.headerInset)
        let screen = try XCTUnwrap(panel.screen).visibleFrame
        let floatingOrigin = NSPoint(x: screen.midX - originalFrame.midX,
                                     y: screen.minY + 12 - originalFrame.minY)
        let release = NSPoint(x: start.x + floatingOrigin.x - home.x,
                              y: start.y + floatingOrigin.y - home.y)
        editor.dragHandle.onBegin?(start)
        editor.dragHandle.onMove?(release)
        editor.dragHandle.onEnd?(release)
        XCTAssertEqual(panel.level, .floating)

        // The old release flight blocked this gesture or erased its resize spring.
        let location = NSPoint(x: originalFrame.midX, y: originalFrame.midY)
        XCTAssertTrue(controller.handleMagnification(delta: 0.1, phase: .began, locationInWindow: location))
        XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
        settle()
        XCTAssertEqual(editor.frame.size, PanelSize.large.dimensions)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(controller.mode, .expanded)
        let visible = editor.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        XCTAssertGreaterThanOrEqual(visible.minY, screen.minY - 1)
        XCTAssertLessThanOrEqual(visible.maxY, screen.maxY + 1)
        XCTAssertEqual(text.string, source)
        XCTAssertEqual(text.selectedRange(), selection)
        let resizedFont = try XCTUnwrap(text.textStorage?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(resizedFont.pointSize, font.pointSize)

        let largeLocation = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
        XCTAssertTrue(controller.handleMagnification(delta: -0.1, phase: .began, locationInWindow: largeLocation))
        XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: largeLocation))
        settle()
        XCTAssertEqual(editor.frame.size, PanelSize.standard.dimensions)
        XCTAssertEqual(text.string, source)
        XCTAssertEqual(text.selectedRange(), selection)

        let returnStart = NSPoint(x: panel.frame.minX + editor.frame.midX,
                                  y: panel.frame.minY + editor.frame.maxY - PanelDocking.headerInset)
        editor.dragHandle.onBegin?(returnStart)
        editor.dragHandle.onMove?(start)
        editor.dragHandle.onEnd?(start)
        settle()
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertEqual(panel.frame.origin, home)
        XCTAssertEqual(editor.frame.size, PanelSize.standard.dimensions)
        controller.collapse()
        settle()
        XCTAssertEqual(controller.mode, .rest)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), source)
    }
}
