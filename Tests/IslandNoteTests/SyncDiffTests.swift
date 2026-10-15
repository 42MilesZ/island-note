import Foundation
import XCTest
@testable import IslandNote

final class SyncDiffTests: XCTestCase {
    func testEmptyAndIdenticalDocuments() {
        for source in ["", "One line", "First\n\nLast\n", "A  \n  B"] {
            let diff = SyncDiff.compare(left: source, right: source)
            assertCoverage(diff)
            XCTAssertTrue(diff.blocks.allSatisfy { $0.kind == .equal })
            XCTAssertFalse(diff.usedCoarseComparison)
        }
    }

    func testChangedWordsAndOneSidedLinesHaveOriginalRanges() {
        let left = "# Title\nThe red fox\nKeep\nRemoved\nEnd\n"
        let right = "# Title\nThe blue fox\nKeep\nAdded\nEnd\n"
        let diff = SyncDiff.compare(left: left, right: right)
        assertCoverage(diff)
        XCTAssertEqual(highlightedText(diff, side: .left), ["r", "d", "Remov"])
        XCTAssertEqual(highlightedText(diff, side: .right), ["blu", "Add"])
        XCTAssertFalse(diff.usedCoarseComparison)

        let insertion = SyncDiff.compare(left: "A\nB\n", right: "A\nNew\nB\n")
        assertCoverage(insertion)
        XCTAssertTrue(insertion.blocks.contains {
            $0.kind == .changed && $0.left.length == 0 && $0.rightLineCount == 1
                && text(insertion.right, at: $0.right) == "New\n"
        })
        XCTAssertEqual(highlightedText(insertion, side: .right), ["New\n"])
    }

    func testTrailingNewlineAndCRLFNormalization() {
        let trailing = SyncDiff.compare(left: "Heading", right: "Heading\n")
        assertCoverage(trailing)
        XCTAssertEqual(highlightedText(trailing, side: .left), [])
        XCTAssertEqual(highlightedText(trailing, side: .right), ["\n"])

        let normalized = SyncDiff.compare(left: "A\r\n  B  \r\n", right: "A\n  B  \n")
        assertCoverage(normalized)
        XCTAssertTrue(normalized.blocks.allSatisfy { $0.kind == .equal })
        XCTAssertEqual(normalized.blocks.first?.left.length, 10)
        XCTAssertEqual(normalized.blocks.first?.right.length, 8)

        let significant = SyncDiff.compare(left: "Line  \r\nNext", right: "Line\nNext")
        assertCoverage(significant)
        XCTAssertTrue(significant.blocks.contains { $0.kind == .changed })
        XCTAssertEqual(highlightedText(significant, side: .left), ["  "])
    }

    func testParagraphBoundariesKeepSoftLineInsideBlock() {
        let left = "A\rB\u{2029}soft\u{2028}line\nEnd"
        let right = "A\rB\u{2029}soft\u{2028}changed\nEnd"
        let diff = SyncDiff.compare(left: left, right: right)
        assertCoverage(diff)
        XCTAssertEqual(diff.blocks.map(\.leftLineCount), [2, 1, 1])
        XCTAssertEqual(diff.blocks.map { text(diff.left, at: $0.left) }, ["A\rB\u{2029}", "soft\u{2028}line\n", "End"])
        XCTAssertFalse(highlightedText(diff, side: .left).joined().contains("\u{2028}"))
    }

    func testChineseEmojiAndCombiningCharactersStayWhole() {
        let left = "前缀👩🏽‍💻 café\n"
        let right = "前缀🧑🏽‍💻 cafa\u{301}\n"
        let diff = SyncDiff.compare(left: left, right: right)
        assertCoverage(diff)
        let leftChanges = highlightedText(diff, side: .left)
        let rightChanges = highlightedText(diff, side: .right)
        XCTAssertTrue(leftChanges.contains("👩🏽‍💻"))
        XCTAssertTrue(rightChanges.contains("🧑🏽‍💻"))
        XCTAssertTrue(leftChanges.contains("é"))
        XCTAssertTrue(rightChanges.contains("a\u{301}"))
        XCTAssertFalse(diff.usedCoarseComparison)
    }

    func testLongSingleLineOnlyMarksActualEdits() {
        let left = String(repeating: "甲", count: 15_000) + "👩🏽‍💻" + String(repeating: "乙", count: 15_000)
        let right = String(repeating: "甲", count: 15_000) + "🧑🏽‍💻" + String(repeating: "乙", count: 15_000)
        let started = Date()
        let diff = SyncDiff.compare(left: left, right: right)
        print("SyncDiff long single line: \(Date().timeIntervalSince(started)) seconds")
        assertCoverage(diff)
        XCTAssertEqual(highlightedText(diff, side: .left), ["👩🏽‍💻"])
        XCTAssertEqual(highlightedText(diff, side: .right), ["🧑🏽‍💻"])
        XCTAssertFalse(diff.usedCoarseComparison)
    }

    func testUnrelatedLongTextAndManyLinesUseBoundedComparison() {
        let left = String(repeating: "甲", count: 15_000)
        let right = String(repeating: "乙", count: 15_000)
        let started = Date()
        let longDiff = SyncDiff.compare(left: left, right: right)
        print("SyncDiff unrelated long text: \(Date().timeIntervalSince(started)) seconds")
        assertCoverage(longDiff)
        XCTAssertTrue(longDiff.usedCoarseComparison)
        XCTAssertEqual(highlightedText(longDiff, side: .left), [left])
        XCTAssertEqual(highlightedText(longDiff, side: .right), [right])

        let oldLines = (0..<2_000).map { "Old \($0)\n" }.joined()
        let newLines = (0..<2_000).map { "New \($0)\n" }.joined()
        let lineStart = Date()
        let lineDiff = SyncDiff.compare(left: oldLines, right: newLines)
        print("SyncDiff 2,000 unrelated lines: \(Date().timeIntervalSince(lineStart)) seconds")
        assertCoverage(lineDiff)
        XCTAssertTrue(lineDiff.usedCoarseComparison)
    }

    func testUniqueLineAnchorSurvivesLargeChangedRegions() {
        let oldPrefix = (0..<800).map { "old \($0)\n" }.joined()
        let newPrefix = (0..<800).map { "new \($0)\n" }.joined()
        let oldSuffix = (0..<800).map { "before \($0)\n" }.joined()
        let newSuffix = (0..<800).map { "after \($0)\n" }.joined()
        let diff = SyncDiff.compare(left: oldPrefix + "Shared anchor\n" + oldSuffix,
                                    right: newPrefix + "Shared anchor\n" + newSuffix)
        assertCoverage(diff)
        XCTAssertEqual(diff.blocks.map(\.kind), [.changed, .equal, .changed])
        XCTAssertEqual(text(diff.left, at: diff.blocks[1].left), "Shared anchor\n")
        XCTAssertTrue(diff.usedCoarseComparison)
    }

    func testRepeatedLinesAndBlankLinesHaveStableRanges() {
        let left = "start\n" + String(repeating: "same\n\n", count: 400) + "old\n" + String(repeating: "same\n\n", count: 400) + "end"
        let right = "start\n" + String(repeating: "same\n\n", count: 400) + "new\n" + String(repeating: "same\n\n", count: 400) + "end"
        let first = SyncDiff.compare(left: left, right: right)
        let second = SyncDiff.compare(left: left, right: right)
        assertCoverage(first)
        XCTAssertEqual(highlightedText(first, side: .left), ["old"])
        XCTAssertEqual(highlightedText(first, side: .right), ["new"])
        XCTAssertEqual(first.blocks.map(\.left), second.blocks.map(\.left))
        XCTAssertEqual(first.blocks.map(\.right), second.blocks.map(\.right))
        XCTAssertFalse(first.usedCoarseComparison)
    }

    private enum Side { case left, right }

    private func highlightedText(_ diff: SyncDiff, side: Side) -> [String] {
        diff.blocks.flatMap { block in
            let source = side == .left ? diff.left : diff.right
            let ranges = side == .left ? block.leftHighlights : block.rightHighlights
            return ranges.map { text(source, at: $0) }
        }
    }

    private func text(_ source: String, at range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    private func assertCoverage(_ diff: SyncDiff, file: StaticString = #filePath, line: UInt = #line) {
        var leftCursor = 0
        var rightCursor = 0
        var rebuiltLeft = ""
        var rebuiltRight = ""
        for block in diff.blocks {
            XCTAssertEqual(block.left.location, leftCursor, file: file, line: line)
            XCTAssertEqual(block.right.location, rightCursor, file: file, line: line)
            rebuiltLeft += text(diff.left, at: block.left)
            rebuiltRight += text(diff.right, at: block.right)
            leftCursor = NSMaxRange(block.left)
            rightCursor = NSMaxRange(block.right)
            for highlight in block.leftHighlights {
                XCTAssertGreaterThanOrEqual(highlight.location, block.left.location, file: file, line: line)
                XCTAssertLessThanOrEqual(NSMaxRange(highlight), NSMaxRange(block.left), file: file, line: line)
            }
            for highlight in block.rightHighlights {
                XCTAssertGreaterThanOrEqual(highlight.location, block.right.location, file: file, line: line)
                XCTAssertLessThanOrEqual(NSMaxRange(highlight), NSMaxRange(block.right), file: file, line: line)
            }
            if block.kind == .equal {
                XCTAssertTrue(block.leftHighlights.isEmpty, file: file, line: line)
                XCTAssertTrue(block.rightHighlights.isEmpty, file: file, line: line)
            }
        }
        XCTAssertEqual(leftCursor, diff.left.utf16.count, file: file, line: line)
        XCTAssertEqual(rightCursor, diff.right.utf16.count, file: file, line: line)
        XCTAssertEqual(rebuiltLeft, diff.left, file: file, line: line)
        XCTAssertEqual(rebuiltRight, diff.right, file: file, line: line)
    }
}
