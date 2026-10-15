import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class FlomoConflictWindowTests: XCTestCase {
    func testLongCopiesScrollIndependentlyWithoutChangingDocumentHeight() throws {
        _ = NSApplication.shared
        let text = String(repeating: "A long paragraph 中文正文, with readable spacing.\n\n", count: 500)
        let controller = FlomoConflictWindowController(conflict: SyncConflict(local: text,
            remote: FlomoMemo(id: "test", content: text, updatedAt: "2026-10-14T18:00:00+08:00")),
            phase: .conflict, lastVerifiedAt: nil, canChoose: true, canMerge: false)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.prepareTextLayout()
        let scroll = try XCTUnwrap(controller.localScroll)
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let height = view.frame.height
        XCTAssertGreaterThan(height, scroll.contentSize.height * 10)
        XCTAssertEqual(view.font?.pointSize, 14)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        let otherOrigin = controller.remoteScroll.contentView.bounds.origin
        for step in 0..<100 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 100))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertEqual(view.frame.height, height)
        }
        XCTAssertEqual(controller.remoteScroll.contentView.bounds.origin, otherOrigin)
        XCTAssertEqual(view.string, text)
        window.setContentSize(NSSize(width: 720, height: 500))
        controller.prepareTextLayout()
        XCTAssertEqual(view.frame.width, scroll.contentSize.width, accuracy: 0.5)
        XCTAssertEqual(view.textContainer!.containerSize.width, view.frame.width - 2 * view.textContainerInset.width, accuracy: 0.5)
        for button in [controller.localButton!, controller.remoteButton!] {
            let frame = button.convert(button.bounds, to: window.contentView)
            XCTAssertTrue(window.contentView!.bounds.contains(frame))
        }
        let left = controller.localButton.convert(controller.localButton.bounds, to: window.contentView)
        let right = controller.remoteButton.convert(controller.remoteButton.bounds, to: window.contentView)
        XCTAssertLessThan(left.maxX, right.minX)
        XCTAssertEqual(left.minY, right.minY, accuracy: 1)
    }

    func testPausedReviewDisablesAllReplacementActionsAndShowsUnknownDates() throws {
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            let controller = FlomoConflictWindowController(conflict: SyncConflict(local: "Local",
                remote: FlomoMemo(id: "test", content: "Remote", updatedAt: "")),
                phase: .conflict, lastVerifiedAt: nil, canChoose: false, canMerge: false)
            defer { controller.window?.close() }
            controller.window?.setContentSize(NSSize(width: 720, height: 500))
            controller.prepareTextLayout()
            XCTAssertFalse(controller.localButton.isEnabled)
            XCTAssertFalse(controller.remoteButton.isEnabled)
            XCTAssertTrue(controller.mergeButton.isEnabled)
            XCTAssertEqual(controller.mergeButton.title, L10n.tr("Resume Sync"))
            let root = try XCTUnwrap(controller.window?.contentView)
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            XCTAssertEqual(fields(root).filter { $0.stringValue == L10n.tr("Update time unavailable") }.count, 2)
            XCTAssertTrue(root.bounds.contains(controller.mergeButton.convert(controller.mergeButton.bounds, to: root)))
        }
    }

    func testServiceDatesPreserveUnknownTimezoneAndDecodeOffsets() {
        XCTAssertNil(FlomoConflictWindowController.remoteDateText(""))
        XCTAssertEqual(FlomoConflictWindowController.remoteDateText("2026-10-14 18:00:00"), "2026-10-14 18:00:00")
        let date = ISO8601DateFormatter().date(from: "2026-10-14T18:00:00+08:00")!
        XCTAssertEqual(FlomoConflictWindowController.remoteDateText("2026-10-14T18:00:00+08:00"),
                       FlomoConflictWindowController.dateText(date))
    }
}
