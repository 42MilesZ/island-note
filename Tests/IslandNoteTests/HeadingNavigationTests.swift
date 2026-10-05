import AppKit
import MarkdownEngine
import XCTest
@testable import IslandNote

@MainActor
final class HeadingNavigationTests: XCTestCase {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.compactMap { find(type, in: $0) }.first
    }

    private func settle(_ interval: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func snapshot(_ editor: NoteEditorView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] else { return }
        editor.wantsLayer = true
        editor.layer?.backgroundColor = NSColor.black.cgColor
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    func testNativeEditorRejectsOversizedPasteWithoutTruncating() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 275), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NoteEditorView(frame: window.contentView!.bounds)
        window.contentView = editor
        editor.string = "Original text"
        editor.setEditingEnabled(true)
        editor.layoutSubtreeIfNeeded()
        settle()
        editor.focus()
        let text = try XCTUnwrap(find(NSTextView.self, in: editor))
        XCTAssertTrue(text.delegate is NativeTextViewCoordinator, "The engine owns its IME and list coordinator")
        text.insertText(String(repeating: "x", count: 30_001), replacementRange: NSRange(location: 0, length: 0))
        settle()
        XCTAssertEqual(text.string, "Original text")
        XCTAssertEqual(editor.string, "Original text")
        text.insertText("New ", replacementRange: NSRange(location: 0, length: 0))
        settle()
        XCTAssertEqual(text.string, "New Original text")
        XCTAssertEqual(editor.string, "New Original text")
        text.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.hasMarkedText)
        text.insertText("你", replacementRange: text.markedRange())
        text.unmarkText()
        settle()
        XCTAssertFalse(editor.hasMarkedText)
        XCTAssertEqual(editor.string, "你New Original text")
        window.close()
    }

    func testOutlineAppearsWhenTypingThirdHeadingAfterOpening() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 275), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NoteEditorView(frame: NSRect(x: 0, y: 0, width: 460, height: 275))
        window.contentView = editor
        editor.isHidden = true
        editor.alphaValue = 0
        editor.string = "# First heading\n\nReadable body text.\n\n## Second heading\n\nMore body text.\n"
        editor.setEditingEnabled(true)
        settle()
        editor.isHidden = false
        editor.alphaValue = 1
        editor.focus()
        settle()
        XCTAssertFalse(editor.outlineModel.isVisible)
        try snapshot(editor, name: "outline-two-headings")
        let text = try XCTUnwrap(find(NSTextView.self, in: editor))
        text.insertText("\n### Third heading\n", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        settle(0.7)
        XCTAssertEqual(editor.outlineModel.headings.count, 3)
        XCTAssertTrue(editor.outlineModel.isVisible)
        editor.outlineModel.hoveredID = editor.outlineModel.headings[1].id
        settle()
        try snapshot(editor, name: "outline-third-heading-added")
        window.close()
    }

    func testNativeNavigationAndResizePreserveTextAndSelection() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 275), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NoteEditorView(frame: NSRect(x: 0, y: 0, width: 460, height: 275))
        window.contentView = editor
        let source = (1...12).map { index in
            "\(String(repeating: "#", count: min(index % 3 + 1, 3))) Section \(index)\n\n" + String(repeating: "A paragraph with enough text to wrap across the note.\n\n", count: 4)
        }.joined(separator: "\n")
        editor.string = source
        editor.setEditingEnabled(true)
        editor.layoutSubtreeIfNeeded()
        settle()
        editor.focus()
        settle()
        let text = try XCTUnwrap(find(NSTextView.self, in: editor))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        text.setSelectedRange(NSRange(location: 10, length: 3))
        let selection = text.selectedRange()
        editor.navigate(to: editor.outlineModel.headings[7])
        settle(0.7)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100)
        XCTAssertEqual(editor.outlineModel.activeID, editor.outlineModel.headings[7].id)
        XCTAssertEqual(text.string, source)
        XCTAssertEqual(text.selectedRange(), selection)
        editor.outlineModel.hoveredID = editor.outlineModel.headings[7].id
        settle()
        try snapshot(editor, name: "outline-standard-hover")
        editor.outlineModel.hoveredID = nil
        window.setContentSize(NSSize(width: 690, height: 550))
        editor.layoutSubtreeIfNeeded()
        settle()
        editor.navigate(to: editor.outlineModel.headings[2])
        settle(0.7)
        XCTAssertEqual(editor.outlineModel.activeID, editor.outlineModel.headings[2].id)
        XCTAssertEqual(text.string, source)
        XCTAssertEqual(text.selectedRange(), selection)

        // Optional native snapshots use only this in-memory fixture, never the Vault.
        if ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] != nil {
            for (name, hovered) in [("outline-rest", nil), ("outline-hover", editor.outlineModel.headings[4].id)] {
                editor.outlineModel.hoveredID = hovered
                settle()
                try snapshot(editor, name: name)
            }
        }
        #if !ISLAND_TESTFLIGHT
        if ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] != nil {
            window.setContentSize(NSSize(width: 460, height: 275))
            editor.layoutSubtreeIfNeeded()
            for (name, phase) in [("sync-merge", SyncPhase.mergeRequired), ("sync-checking", .checking),
                                  ("sync-synced", .synced), ("sync-offline", .connectionFailed),
                                  ("sync-formatting", .formattingChanged)] {
                editor.showSyncStatus(phase, detail: "Status details and next action")
                settle(0.2)
                try snapshot(editor, name: name)
            }
            let statusButton = try XCTUnwrap(find(StatusIndicatorButton.self, in: editor))
            editor.showSyncStatus(.synced, detail: "Both copies match")
            statusButton.onHover?(true)
            settle(0.4)
            try snapshot(editor, name: "status-hover-synced")
            editor.showSyncStatus(.conflict, detail: "Both copies changed")
            settle(0.2)
            try snapshot(editor, name: "status-hover-conflict")
            statusButton.onHover?(false)
            settle(0.2)
            editor.showSyncStatus(.synced, detail: "Both copies match")
            editor.flashSavedIndicator()
            settle(0.2)
            try snapshot(editor, name: "status-local-saved")
            editor.showSaveError("Local file is unavailable")
            editor.showSyncStatus(.synced, detail: "Both copies match")
            settle(0.2)
            try snapshot(editor, name: "status-local-error")
        }
        #endif
        let rail = try XCTUnwrap(find(HeadingOutlineHost.self, in: editor))
        XCTAssertNil(rail.hitTest(NSPoint(x: rail.frame.minX + 50, y: rail.frame.midY)), "Preview must not steal text clicks")
        editor.navigate(to: try XCTUnwrap(editor.outlineModel.headings.last))
        settle(0.7)
        XCTAssertEqual(editor.outlineModel.activeID, editor.outlineModel.headings.last?.id)
        editor.string = "# Only one heading\n"
        settle()
        XCTAssertFalse(editor.outlineModel.isVisible)
        XCTAssertNil(rail.hitTest(NSPoint(x: rail.frame.minX + 5, y: rail.frame.midY)))
        window.close()
    }
}
