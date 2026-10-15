import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class SyncDiffPresentationTests: XCTestCase {
    private func controller(left: String, right: String, canMerge: Bool = true) -> FlomoConflictWindowController {
        _ = NSApplication.shared
        return FlomoConflictWindowController(conflict: SyncConflict(local: left,
            remote: FlomoMemo(id: "fixture", content: right, updatedAt: "2026-10-15T08:30:00+08:00")),
            phase: canMerge ? .conflict : .verifyWrite, lastVerifiedAt: Date(timeIntervalSince1970: 1_792_000_000),
            canChoose: true, canMerge: canMerge, mergeUnavailableReason: canMerge ? nil : "Last upload is awaiting verification.",
            preparedComparison: SyncDiff.compare(left: left, right: right))
    }

    private func assertAligned(_ controller: FlomoConflictWindowController, file: StaticString = #filePath, line: UInt = #line) throws {
        let presentation = try XCTUnwrap(controller.presentation, file: file, line: line)
        for (index, block) in presentation.blocks.enumerated() {
            for (scroll, range) in [(controller.localScroll!, block.left), (controller.remoteScroll!, block.right)] where range.length > 0 {
                let text = try XCTUnwrap(scroll.documentView as? SyncDiffTextView, file: file, line: line)
                let top = text.boundary(range.location) + text.textContainerOrigin.y
                XCTAssertEqual(top, controller.alignedBlocks[index].top, accuracy: 1, "Corresponding blocks must share the same displayed top", file: file, line: line)
            }
        }
        XCTAssertEqual(controller.localScroll.documentView!.frame.height, controller.remoteScroll.documentView!.frame.height, accuracy: 1, file: file, line: line)
    }

    func testInsertedRemovedAndWrappedBlocksActuallyAlignAcrossResize() throws {
        let common = "共同段落，保持普通文本。\n"
        let left = "仅左侧第一段\n" + common + String(repeating: "左侧的长段落，需要在窄窗口中自然换行。", count: 16) + "\n" + common + "结尾\n"
        let right = common + "短修改\n" + common + String(repeating: "仅右侧的新增内容。\n", count: 8) + "结尾\n"
        let review = controller(left: left, right: right)
        defer { review.window?.close() }
        for size in [NSSize(width: 880, height: 680), NSSize(width: 720, height: 500), NSSize(width: 1040, height: 720)] {
            review.window?.setContentSize(size); review.prepareTextLayout()
            try assertAligned(review)
            XCTAssertEqual((review.localScroll.documentView as? NSTextView)?.string, left)
            XCTAssertEqual((review.remoteScroll.documentView as? NSTextView)?.string, right)
        }
    }

    func testFoldingAndClipboardPreserveEveryOriginalCharacter() throws {
        let before = (0..<40).map { "相同段落 \($0) 👨‍👩‍👧‍👦 e\u{301}\n" }.joined()
        let after = (0..<40).map { "共同结尾 \($0)\n" }.joined()
        let left = before + "明天上午开会\n" + after
        let right = before + "明天下午开会\n新增一项\n" + after
        let diff = SyncDiff.compare(left: left, right: right)
        for collapsed in [false, true] {
            let presentation = SyncDiffPresentation(diff: diff, collapseUnchanged: collapsed)
            for side in [presentation.left, presentation.right] {
                XCTAssertEqual(side.originalText(in: NSRange(location: 0, length: side.text.utf16.count)), side.original)
                for span in side.spans where !span.folded {
                    XCTAssertEqual(side.originalText(in: span.display), (side.original as NSString).substring(with: span.source))
                }
            }
            XCTAssertEqual(presentation.blocks.contains(where: \.folded), collapsed)
        }
        let review = controller(left: left, right: right)
        defer { review.window?.close() }
        review.moreMenu.performActionForItem(at: review.moreMenu.items.firstIndex { $0 === review.collapseMenuItem }!)
        XCTAssertTrue(review.isUnchangedCollapsed)
        try assertAligned(review)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for scroll in [review.localScroll!, review.remoteScroll!] {
            let view = try XCTUnwrap(scroll.documentView as? SyncDiffTextView)
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
            pasteboard.clearContents()
            XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
            XCTAssertEqual(pasteboard.string(forType: .string), scroll === review.localScroll ? left : right)
        }
    }

    func testLongScrollDoesNotRelayoutAndLockedOffsetsStayIdentical() throws {
        let common = (0..<900).map { "段落 \($0)：中文内容与 English paragraph，保留相同的内容用于连续滚动。\n" }
        let left = common.enumerated().map { index, line in index % 80 == 0 ? line + "仅左侧的内容\n" : line }.joined()
        let right = common.enumerated().map { index, line in index % 95 == 0 ? line + "仅右侧新增一项\n" : line }.joined()
        let review = controller(left: left, right: right)
        defer { review.window?.close() }
        review.showWindow(nil); review.prepareTextLayout()
        try assertAligned(review)
        let passes = review.layoutPassCount
        let leftScroll = review.localScroll!, rightScroll = review.remoteScroll!
        let heights = [leftScroll.documentView!.frame.height, rightScroll.documentView!.frame.height]
        var samples: [Double] = []
        for step in 0..<600 {
            let driving = step % 2 == 0 ? leftScroll : rightScroll
            let clip = driving.contentView
            let range = max(0, clip.documentRect.height - clip.bounds.height)
            let fraction = CGFloat(step % 200) / 199
            let start = ProcessInfo.processInfo.systemUptime
            clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.minY + fraction * range))
            driving.reflectScrolledClipView(clip)
            // Include real viewport drawing periodically, rather than measuring
            // only cached coordinates. Never replay a gesture on user notes.
            if step % 10 == 0 { review.window?.displayIfNeeded() }
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(leftScroll.contentView.bounds.minY - leftScroll.contentView.documentRect.minY,
                           rightScroll.contentView.bounds.minY - rightScroll.contentView.documentRect.minY, accuracy: 1)
            XCTAssertEqual(review.layoutPassCount, passes)
            XCTAssertEqual(leftScroll.documentView!.frame.height, heights[0])
            XCTAssertEqual(rightScroll.documentView!.frame.height, heights[1])
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        print("DIFF_SCROLL samples=600 p95_ms=\(p95) max_ms=\(samples.last!) layout_passes_during_scroll=\(review.layoutPassCount - passes)")
        if let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] {
            let result: [String: Any] = ["samples": samples.count, "p95_ms": p95, "max_ms": samples.last!, "layout_passes_during_scroll": review.layoutPassCount - passes]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("scroll-performance.json"))
        }
        review.scrollLockButton.performClick(nil)
        let peer = rightScroll.contentView.bounds.origin
        leftScroll.contentView.scroll(to: NSPoint(x: 0, y: leftScroll.contentView.documentRect.minY))
        XCTAssertEqual(rightScroll.contentView.bounds.origin, peer)
        review.scrollLockButton.performClick(nil)
        XCTAssertEqual(leftScroll.contentView.bounds.minY - leftScroll.contentView.documentRect.minY,
                       rightScroll.contentView.bounds.minY - rightScroll.contentView.documentRect.minY, accuracy: 1)
    }

    func testNavigationIsInterruptibleAndDoesNotRecomputeLayout() throws {
        let common = String(repeating: "共同段落内容\n", count: 30)
        let review = controller(left: "甲\n" + common + "乙\n" + common + "丙\n",
                                right: "改甲\n" + common + "改乙\n" + common + "改丙\n")
        defer { review.window?.close() }
        let passes = review.layoutPassCount
        review.nextDifferenceButton.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        let moving = review.localScroll.contentView.bounds.minY
        review.previousDifferenceButton.performClick(nil)
        let reversed = review.localScroll.contentView.bounds.minY
        XCTAssertEqual(moving, reversed, accuracy: 1, "Reversal must resume at its visible position")
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(review.layoutPassCount, passes)
        XCTAssertEqual(review.differenceLabel.stringValue, L10n.format("Difference %d of %d", 1, 3))
    }

    func testUnlockingDuringNavigationStopsBothViewsImmediately() {
        let common = String(repeating: "共同段落内容\n", count: 80)
        let review = controller(left: "甲\n" + common + "乙\n", right: "改甲\n" + common + "改乙\n")
        defer { review.window?.close() }
        review.nextDifferenceButton.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        review.scrollLockButton.performClick(nil)
        let positions = [review.localScroll.contentView.bounds.origin, review.remoteScroll.contentView.bounds.origin]
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(review.localScroll.contentView.bounds.origin, positions[0])
        XCTAssertEqual(review.remoteScroll.contentView.bounds.origin, positions[1])
    }

    func testPureInsertionAndDeletionOnlyDecorateTheChangedSide() throws {
        for (left, right, changedSide) in [("abc\n", "abXc\n", 1), ("abXc\n", "abc\n", 0)] {
            let review = controller(left: left, right: right)
            defer { review.window?.close() }
            for (index, scroll) in [review.localScroll!, review.remoteScroll!].enumerated() {
                let view = try XCTUnwrap(scroll.documentView as? SyncDiffTextView)
                XCTAssertEqual(view.decorations.contains(where: \.changed), index == changedSide)
                XCTAssertEqual(view.side.highlights.isEmpty, index != changedSide)
            }
        }
    }

    func testPeerComparisonUsesTheSameHighlightAndOnlyMarksActualDifferences() throws {
        let review = controller(left: "abc\n", right: "abXc\n")
        defer { review.window?.close() }
        let left = try XCTUnwrap(review.localScroll.documentView as? SyncDiffTextView)
        let right = try XCTUnwrap(review.remoteScroll.documentView as? SyncDiffTextView)
        XCTAssertNil(left.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(right.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        let highlight = try XCTUnwrap(right.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: nil) as? NSColor)
        let reversed = controller(left: "abXc\n", right: "abc\n")
        defer { reversed.window?.close() }
        let reversedLeft = try XCTUnwrap(reversed.localScroll.documentView as? SyncDiffTextView)
        XCTAssertEqual(reversedLeft.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: nil) as? NSColor, highlight)
    }

    func testMissingParagraphLabelsAreSymmetricAndNeverBecomeSourceText() throws {
        let common = "共同内容\n"
        let full = common + "只在这一份有的段落\n" + common
        for (left, right, missingSide) in [(full, common + common, 1), (common + common, full, 0)] {
            let review = controller(left: left, right: right)
            defer { review.window?.close() }
            try assertAligned(review)
            for (index, scroll) in [review.localScroll!, review.remoteScroll!].enumerated() {
                let view = try XCTUnwrap(scroll.documentView as? SyncDiffTextView)
                XCTAssertEqual(view.decorations.contains(where: \.missing), index == missingSide)
                XCTAssertFalse(view.string.contains(L10n.tr("No corresponding paragraph in this copy")))
                XCTAssertEqual(view.side.originalText(in: NSRange(location: 0, length: view.string.utf16.count)), index == 0 ? left : right)
                for (offset, unit) in view.string.utf16.enumerated() where unit == 10 {
                    XCTAssertNil(view.textStorage?.attribute(.backgroundColor, at: offset, effectiveRange: nil),
                                 "Paragraph spacing and alignment gaps must not inherit a character highlight")
                }
            }
        }
    }

    func testDenseDifferencesBuildContiguousDisplayRangesAndPreserveUnicode() {
        let left = (0..<2_000).map { "共同 \($0) 👨‍👩‍👧‍👦\n左侧\n" }.joined()
        let right = (0..<2_000).map { "共同 \($0) 👨‍👩‍👧‍👦\n右侧\n" }.joined()
        let diff = SyncDiff.compare(left: left, right: right)
        let start = ProcessInfo.processInfo.systemUptime
        let presentation = SyncDiffPresentation(diff: diff, collapseUnchanged: false)
        print("DIFF_DENSE blocks=\(presentation.blocks.count) presentation_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        XCTAssertGreaterThan(presentation.blocks.count, 3_000)
        for side in [presentation.left, presentation.right] {
            XCTAssertEqual(side.text, side.original)
            XCTAssertEqual(side.displayLength, side.text.utf16.count)
            var end = 0
            for span in side.spans { XCTAssertEqual(span.display.location, end); end = NSMaxRange(span.display) }
            XCTAssertEqual(end, side.displayLength)
        }
    }

    func testBackgroundComparisonCompletesAndClosingCancelsPresentation() async throws {
        _ = NSApplication.shared
        let conflict = SyncConflict(local: String(repeating: "中文长文与 emoji 👨‍👩‍👧‍👦\n", count: 800),
                                    remote: FlomoMemo(id: "test", content: "短版本", updatedAt: ""))
        let review = FlomoConflictWindowController(conflict: conflict, phase: .conflict, lastVerifiedAt: nil, canChoose: true, canMerge: true)
        defer { review.window?.close() }
        XCTAssertNil(review.comparison)
        XCTAssertFalse(review.localButton.isEnabled)
        let deadline = Date().addingTimeInterval(5)
        while review.comparison == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(review.comparison)
        XCTAssertTrue(review.localButton.isEnabled)
        try assertAligned(review)
        let closed = FlomoConflictWindowController(conflict: conflict, phase: .conflict, lastVerifiedAt: nil, canChoose: true, canMerge: true)
        closed.window?.close()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(closed.comparison)
        XCTAssertFalse(closed.window?.isVisible ?? true)
    }

    func testRenderedDiffViewsInBothLanguagesAndAppearances() throws {
        guard let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] else { return }
        let original = L10n.language
        defer { L10n.language = original }
        let common = "项目讨论记录\n\n这次先把冲突看清楚，再决定保留哪一份。相同内容不做标注。\n\n"
        let middle = (0..<24).map { "共同记录 \($0 + 1)：保持简单、清楚，保留必要的上下文。\n" }.joined()
        let left = common + "明天上午十点讨论交互方案。\n\n仅在 Island Note：先整理用户反馈。\n\n" + middle + "本次先完成草稿。\n"
        let right = common + "明天下午两点讨论交互方案。\n\n" + middle + "本次先完成可测试的原型。\n另外补充一轮长文滚动验收。\n"
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            for dark in [false, true] {
                for width: CGFloat in [720, 880] {
                    for folded in [false, true] {
                        let review = controller(left: left, right: right)
                        defer { review.window?.close() }
                        review.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        review.window?.setContentSize(NSSize(width: width, height: width == 720 ? 500 : 680))
                        review.showWindow(nil); review.prepareTextLayout()
                        if folded { review.moreMenu.performActionForItem(at: review.moreMenu.items.firstIndex { $0 === review.collapseMenuItem }!) }
                        try assertAligned(review)
                        let root = try XCTUnwrap(review.window?.contentView)
                        review.window?.displayIfNeeded()
                        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        let name = "diff-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width))-\(folded ? "folded" : "full").png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                }
            }
        }
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            let review = controller(left: left, right: right, canMerge: false)
            defer { review.window?.close() }
            review.window?.setContentSize(NSSize(width: 720, height: 500))
            review.showWindow(nil); review.prepareTextLayout()
            let root = try XCTUnwrap(review.window?.contentView)
            review.window?.displayIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("diff-\(language.rawValue)-blocked.png"))
        }
    }

    func testRenderedMissingParagraphsInBothDirectionsAndLanguages() throws {
        guard let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] else { return }
        let original = L10n.language
        defer { L10n.language = original }
        let common = "两份共有的内容，保持普通正文。\n"
        let full = common + "这段只存在于其中一份。这里是在比较当前的两份内容，尚未决定保留哪一份。\n" + common
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            for dark in [false, true] {
                for missingLeft in [false, true] {
                    let review = controller(left: missingLeft ? common + common : full, right: missingLeft ? full : common + common)
                    defer { review.window?.close() }
                    review.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    review.window?.setContentSize(NSSize(width: 720, height: 500))
                    review.showWindow(nil); review.prepareTextLayout()
                    try assertAligned(review)
                    let root = try XCTUnwrap(review.window?.contentView)
                    review.window?.displayIfNeeded()
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    let name = "peer-\(language.rawValue)-\(dark ? "dark" : "light")-missing-\(missingLeft ? "left" : "right").png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }
}
