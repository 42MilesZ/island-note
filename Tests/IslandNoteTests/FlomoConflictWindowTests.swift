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

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func render(_ controller: FlomoConflictWindowController, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] else { return }
        let window = try XCTUnwrap(controller.window), root = try XCTUnwrap(window.contentView)
        controller.showWindow(nil)
        controller.prepareTextLayout()
        for button in [controller.scrollLockButton!, controller.moreButton!] {
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(button.frame.width, 36, accuracy: 0.1)
            XCTAssertEqual(button.frame.height, 36, accuracy: 0.1)
            XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
        }
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
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
                    try render(controller, name: "\(language == .chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(locked ? "locked" : "unlocked")")
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
            let resume = try XCTUnwrap(controller.resumeButton)
            XCTAssertTrue(resume.isEnabled)
            XCTAssertEqual(resume.title, L10n.tr("Resume Sync"))
            XCTAssertFalse(controller.moreMenu.items[0].isEnabled)
            let root = try XCTUnwrap(controller.window?.contentView)
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            XCTAssertEqual(fields(root).filter { $0.stringValue == L10n.tr("Update time unavailable") }.count, 2)
            XCTAssertTrue(root.bounds.contains(resume.convert(resume.bounds, to: root)))
            try render(controller, name: "\(language.rawValue)-paused")
        }
    }

    func testCompactMetadataAndOnlyOneSelectionPerCardAtBothWindowSizes() throws {
        _ = NSApplication.shared
        let original = L10n.language
        defer { L10n.language = original }
        let date = Date(timeIntervalSince1970: 1_792_001_123)
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            for dark in [false, true] {
                for size in [NSSize(width: 720, height: 500), NSSize(width: 880, height: 680)] {
                    let controller = FlomoConflictWindowController(conflict: SyncConflict(local: String(repeating: paragraph, count: 60),
                        remote: FlomoMemo(id: "fixture", content: String(repeating: paragraph, count: 40), updatedAt: "2026-10-15T08:15:27+08:00"),
                        localUpdatedAt: date, capturedAt: date.addingTimeInterval(600)),
                        phase: .conflict, lastVerifiedAt: date.addingTimeInterval(-600), canChoose: true, canMerge: true)
                    let window = try XCTUnwrap(controller.window)
                    defer { window.close() }
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setContentSize(size); controller.prepareTextLayout()
                    let root = try XCTUnwrap(window.contentView), views = descendants(root)
                    for button in [controller.localButton!, controller.remoteButton!] {
                        let card = try XCTUnwrap(button.superview)
                        XCTAssertEqual(descendants(card).filter { $0 is NSButton }.count, 1)
                        XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
                        XCTAssertEqual(button.font?.pointSize, 14)
                    }
                    XCTAssertEqual(controller.localButton.title, L10n.tr("Use Island Note"))
                    XCTAssertEqual(controller.remoteButton.title, L10n.tr("Use Flomo"))
                    XCTAssertNil(controller.resumeButton)
                    XCTAssertEqual(controller.moreButton.frame.size, controller.scrollLockButton.frame.size)
                    XCTAssertEqual(controller.moreButton.frame.height, 36, accuracy: 0.1)
                    XCTAssertEqual(views.filter { $0 is NSButton }.count, 4, "Two choices plus lock and more icon controls")
                    let metadata = views.filter { $0.accessibilityIdentifier() == "syncReview.metadata" }
                    XCTAssertEqual(metadata.count, 6)
                    for tag in metadata {
                        XCTAssertEqual(tag.accessibilityRole(), .staticText)
                        XCTAssertTrue(root.bounds.contains(tag.convert(tag.bounds, to: root)))
                        for child in descendants(tag).compactMap({ $0 as? NSTextField }) {
                            let available = child.bounds.width
                            let needed = child.intrinsicContentSize.width
                            XCTAssertGreaterThanOrEqual(available + 1, needed, "Known metadata must fit without truncation: \(child.stringValue)")
                        }
                    }
                    XCTAssertTrue(metadata.contains { $0.toolTip?.contains(FlomoConflictWindowController.dateText(date)) == true })
                    XCTAssertFalse(views.contains { $0.accessibilityIdentifier() == "syncReview.warning" })
                    let fields = views.compactMap { $0 as? NSTextField }.map(\.stringValue)
                    XCTAssertTrue(fields.contains(L10n.tr("Choose one copy for both")))
                    XCTAssertFalse(fields.contains("Updates Flomo"))
                    XCTAssertFalse(fields.contains("Updates Island Note"))
                    XCTAssertTrue(controller.moreMenu.items[0].isEnabled)
                    XCTAssertEqual(controller.moreMenu.items[0].title, L10n.tr("Combine Both Copies"))
                    try render(controller, name: "\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))")
                }
            }
        }
    }

    func testRefreshFailureAndUnconfirmedUploadRemainVisible() throws {
        _ = NSApplication.shared
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            for phase in [SyncPhase.offline, .verifyWrite] {
                let error = phase == .offline ? "Could not refresh the remote copy. Please try again when your connection is available." : nil
                let controller = FlomoConflictWindowController(conflict: SyncConflict(local: "Local", remote: FlomoMemo(id: "fixture", content: "Remote", updatedAt: "")),
                    phase: phase, lastVerifiedAt: nil, canChoose: true, canMerge: false, reviewError: error)
                defer { controller.window?.close() }
                controller.window?.setContentSize(NSSize(width: 720, height: 500)); controller.prepareTextLayout()
                let root = try XCTUnwrap(controller.window?.contentView)
                let warning = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "syncReview.warning" } as? NSTextField)
                XCTAssertEqual(warning.stringValue, error ?? L10n.tr("Last upload unconfirmed."))
                XCTAssertTrue(root.bounds.contains(warning.convert(warning.bounds, to: root)))
                XCTAssertFalse(controller.moreMenu.items[0].isEnabled)
                XCTAssertGreaterThan(controller.localScroll.bounds.height, 100)
                try render(controller, name: "\(language.rawValue)-\(phase == .offline ? "offline" : "unconfirmed")")
            }
        }
    }

    func testSourceButtonsAndSecondaryMenuReturnTheCorrespondingChoice() async throws {
        for index in 0..<4 {
            let controller = fixture(local: "Local", remote: "Remote")
            Task { @MainActor in
                switch index {
                case 0: controller.localButton.performClick(nil)
                case 1: controller.remoteButton.performClick(nil)
                case 2: controller.moreMenu.performActionForItem(at: 2)
                default: controller.window?.close()
                }
            }
            let result = await controller.run()
            switch (index, result) {
            case (0, .choose(.local)), (1, .choose(.remote)), (2, nil), (3, nil): break
            default: XCTFail("Selection mapped to the wrong action: \(index)")
            }
            XCTAssertFalse(controller.window?.isVisible ?? true)
        }
        let controller = FlomoConflictWindowController(conflict: SyncConflict(local: "Local", remote: FlomoMemo(id: "fixture", content: "Remote", updatedAt: "")),
            phase: .mergeRequired, lastVerifiedAt: nil, canChoose: true, canMerge: true)
        Task { @MainActor in controller.moreMenu.performActionForItem(at: 0) }
        guard case .choose(.merge) = await controller.run() else { return XCTFail("Combine must retain the merge action") }
    }

    func testEscapeCancelsFromFocusedTextAndPausedReviewCanResume() async throws {
        let controller = fixture(local: "Local", remote: "Remote")
        Task { @MainActor in
            let window = controller.window!
            XCTAssertTrue(window.firstResponder is NSTextView)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            window.sendEvent(event)
            XCTAssertFalse(window.isVisible, "Escape must still dismiss without a visible Later button")
            if window.isVisible { window.close() }
        }
        let cancelled = await controller.run()
        XCTAssertNil(cancelled)
        let paused = FlomoConflictWindowController(conflict: SyncConflict(local: "Local", remote: FlomoMemo(id: "fixture", content: "Remote", updatedAt: "")),
            phase: .conflict, lastVerifiedAt: nil, canChoose: false, canMerge: false)
        Task { @MainActor in paused.resumeButton?.performClick(nil) }
        guard case .resume = await paused.run() else { return XCTFail("Resume must remain available when paused") }
    }

    func testServiceDatesPreserveUnknownTimezoneAndDecodeOffsets() {
        XCTAssertNil(FlomoConflictWindowController.remoteDateText(""))
        XCTAssertEqual(FlomoConflictWindowController.remoteDateText("2026-10-14 18:00:00"), "2026-10-14 18:00:00")
        let date = ISO8601DateFormatter().date(from: "2026-10-14T18:00:00+08:00")!
        XCTAssertEqual(FlomoConflictWindowController.remoteDateText("2026-10-14T18:00:00+08:00"),
                       FlomoConflictWindowController.dateText(date))
    }
}
