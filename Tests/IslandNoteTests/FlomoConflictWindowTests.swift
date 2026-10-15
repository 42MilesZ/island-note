import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class FlomoConflictWindowTests: XCTestCase {
    private let paragraph = "A paragraph 中文正文 with text that wraps on narrow viewports.\n\n"

    private func fixture(local: String? = nil, remote: String? = nil) -> FlomoConflictWindowController {
        _ = NSApplication.shared
        let controller = FlomoConflictWindowController(conflict: SyncConflict(
            local: local ?? String(repeating: paragraph, count: 400),
            remote: FlomoMemo(id: "fixture", content: remote ?? String(repeating: paragraph, count: 170), updatedAt: "")),
            phase: .conflict, lastVerifiedAt: nil, canChoose: true, canMerge: false)
        controller.prepareTextLayout()
        return controller
    }

    private func scroll(_ view: NSScrollView, to progress: CGFloat) {
        let clip = view.contentView
        let range = max(0, clip.documentRect.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.minY + progress * range))
        view.reflectScrolledClipView(clip)
    }

    private func progress(_ view: NSScrollView) -> CGFloat {
        let clip = view.contentView
        let range = max(0, clip.documentRect.height - clip.bounds.height)
        return range > 0 ? (clip.bounds.minY - clip.documentRect.minY) / range : 0
    }

    func testLockedCopiesScrollBothWaysWithDifferentDocumentHeights() throws {
        let controller = fixture()
        defer { controller.window?.close() }
        XCTAssertTrue(controller.isScrollLocked)
        XCTAssertEqual(controller.scrollLockButton.state, .on)
        let left = try XCTUnwrap(controller.localScroll), right = try XCTUnwrap(controller.remoteScroll)
        XCTAssertEqual(progress(left), 0, accuracy: 0.0001)
        XCTAssertEqual(progress(right), 0, accuracy: 0.0001)
        controller.window?.setContentSize(NSSize(width: 720, height: 500))
        controller.prepareTextLayout()
        XCTAssertEqual(progress(left), 0, accuracy: 0.0001)
        XCTAssertEqual(progress(right), 0, accuracy: 0.0001)
        for scroll in [left, right] {
            let view = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertLessThanOrEqual(scroll.contentView.documentVisibleRect.minY, view.textContainerOrigin.y,
                                     "Resizing a fresh comparison must keep its first line visible")
        }
        let leftHeight = left.documentView!.frame.height, rightHeight = right.documentView!.frame.height
        XCTAssertGreaterThan(leftHeight, rightHeight * 2)
        for source in [left, right] {
            for value: CGFloat in [0.1, 0.4, 0.85, 1, 0] {
                scroll(source, to: value)
                XCTAssertEqual(progress(left), value, accuracy: 0.001)
                XCTAssertEqual(progress(right), value, accuracy: 0.001)
            }
        }
        for step in 0..<100 {
            scroll(left, to: CGFloat(step) / 100)
            XCTAssertEqual(progress(right), progress(left), accuracy: 0.001)
            XCTAssertEqual(left.documentView!.frame.height, leftHeight)
            XCTAssertEqual(right.documentView!.frame.height, rightHeight)
        }
    }

    func testUnlockKeepsPositionsAndRelockUsesTheLastScrolledCopy() throws {
        let controller = fixture()
        defer { controller.window?.close() }
        let left = try XCTUnwrap(controller.localScroll), right = try XCTUnwrap(controller.remoteScroll)
        scroll(left, to: 0.35)
        let originalRight = right.contentView.bounds.origin
        controller.scrollLockButton.performClick(nil)
        XCTAssertFalse(controller.isScrollLocked)
        XCTAssertEqual(controller.scrollLockButton.state, .off)
        XCTAssertEqual(controller.scrollLockButton.toolTip, L10n.tr("Lock scrolling"))
        scroll(left, to: 0.75)
        XCTAssertEqual(right.contentView.bounds.origin, originalRight)
        let independentLeft = left.contentView.bounds.origin
        scroll(right, to: 0.2)
        XCTAssertEqual(left.contentView.bounds.origin, independentLeft)
        let drivingOrigin = right.contentView.bounds.origin
        controller.scrollLockButton.performClick(nil)
        XCTAssertTrue(controller.isScrollLocked)
        XCTAssertEqual(progress(left), 0.2, accuracy: 0.001)
        XCTAssertEqual(right.contentView.bounds.origin, drivingOrigin)
        XCTAssertEqual(controller.scrollLockButton.toolTip, L10n.tr("Unlock scrolling"))
    }

    func testLockedScrollingHandlesEmptyAndNonOverflowingCopies() throws {
        for short in ["", "Short note"] {
            let controller = fixture(remote: short)
            defer { controller.window?.close() }
            let left = try XCTUnwrap(controller.localScroll), right = try XCTUnwrap(controller.remoteScroll)
            scroll(left, to: 0.8)
            XCTAssertEqual(progress(left), 0.8, accuracy: 0.001)
            XCTAssertEqual(progress(right), 0)
            XCTAssertTrue(right.contentView.bounds.minY.isFinite)
            controller.scrollLockButton.performClick(nil)
            controller.scrollLockButton.performClick(nil)
            XCTAssertEqual(progress(left), 0.8, accuracy: 0.001)
        }
    }

    func testLockIconReceivesNativeMouseClicks() throws {
        let controller = fixture()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        controller.prepareTextLayout()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let button = try XCTUnwrap(controller.scrollLockButton)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: timestamp + 0.02, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        XCTAssertTrue(window.contentView!.hitTest(window.contentView!.convert(point, from: nil)) === button)
        XCTAssertTrue(button.cell!.hitTest(for: down, in: button.bounds, of: button).contains(.trackableArea))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        // Native buttons may finish tracking on the next application dispatch.
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
        XCTAssertFalse(controller.isScrollLocked)
        XCTAssertEqual(button.state, .off)
    }

    func testResizingKeepsCopiesLinkedAndDoesNotMoveUnlockedPeer() throws {
        let controller = fixture()
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        let left = try XCTUnwrap(controller.localScroll), right = try XCTUnwrap(controller.remoteScroll)
        scroll(right, to: 0.6)
        for size in [NSSize(width: 720, height: 500), NSSize(width: 1020, height: 740)] {
            window.setContentSize(size)
            controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
            XCTAssertEqual(progress(left), progress(right), accuracy: 0.001)
            scroll(left, to: 0.45)
            XCTAssertEqual(progress(right), 0.45, accuracy: 0.001)
        }
        controller.scrollLockButton.performClick(nil)
        window.setContentSize(NSSize(width: 880, height: 680))
        controller.prepareTextLayout()
        let otherOrigin = right.contentView.bounds.origin
        scroll(left, to: 0.8)
        XCTAssertEqual(right.contentView.bounds.origin, otherOrigin)
    }

    func testLockControlFitsBothLanguagesAndAppearancesAtMinimumSize() throws {
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            for dark in [false, true] {
                for locked in [true, false] {
                    let controller = fixture()
                    let window = try XCTUnwrap(controller.window)
                    defer { window.close() }
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setContentSize(NSSize(width: 720, height: 500))
                    controller.prepareTextLayout()
                    if !locked { controller.scrollLockButton.performClick(nil) }
                    let button = try XCTUnwrap(controller.scrollLockButton)
                    let root = try XCTUnwrap(window.contentView)
                    XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
                    XCTAssertGreaterThanOrEqual(button.frame.width, 32)
                    XCTAssertGreaterThanOrEqual(button.frame.height, 32)
                    XCTAssertNotNil(button.image)
                    XCTAssertEqual(button.accessibilityLabel(), L10n.tr("Synchronized scrolling"))
                    XCTAssertEqual(button.accessibilityRole(), .checkBox)
                    XCTAssertEqual(button.accessibilityValue() as? Int, locked ? 1 : 0)
                    if let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] {
                        window.displayIfNeeded()
                        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        let name = "\(language == .chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(locked ? "locked" : "unlocked").png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                }
            }
        }
    }

    func testLongCopiesScrollIndependentlyWithoutChangingDocumentHeight() throws {
        _ = NSApplication.shared
        let text = String(repeating: "A long paragraph 中文正文, with readable spacing.\n\n", count: 500)
        let controller = FlomoConflictWindowController(conflict: SyncConflict(local: text,
            remote: FlomoMemo(id: "test", content: text, updatedAt: "2026-10-14T18:00:00+08:00")),
            phase: .conflict, lastVerifiedAt: nil, canChoose: true, canMerge: false)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.prepareTextLayout()
        controller.scrollLockButton.performClick(nil)
        XCTAssertFalse(controller.isScrollLocked)
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
