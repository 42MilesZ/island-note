import Foundation
import XCTest
@testable import IslandNote

final class SyncMergeTests: XCTestCase {
    func testSharedBeginningMiddleAndEndKeepBothDistinctChanges() {
        let local = "# Note\nStart\nLocal before\nShared middle\nLocal after\nEnd"
        let remote = "# Note\nStart\nRemote before\nShared middle\nRemote after\nEnd"
        let result = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertEqual(occurrences("# Note", in: result), 1)
        XCTAssertEqual(occurrences("Shared middle", in: result), 1)
        XCTAssertEqual(occurrences("End", in: result), 1)
        XCTAssertLessThan(index(of: "Local before", in: result), index(of: "Remote before", in: result))
        XCTAssertLessThan(index(of: "Remote before", in: result), index(of: "Shared middle", in: result))
        XCTAssertLessThan(index(of: "Local after", in: result), index(of: "Remote after", in: result))
    }

    func testUnrelatedDocumentsHaveAParagraphBreak() {
        let result = SyncMerge.combine(local: "Local idea", remote: "Remote idea").text
        XCTAssertEqual(result, "Local idea\n\nRemote idea")
    }

    func testSimilarRewordingKeepsBothVersionsForEditing() {
        let local = "# Plan\nAdd a marker to the note."
        let remote = "# Plan\nAnnotate the note with a marker."
        let result = SyncMerge.combine(local: local, remote: remote).text
        XCTAssertTrue(result.contains("Add a marker to the note."))
        XCTAssertTrue(result.contains("Annotate the note with a marker."))
    }

    func testExactParagraphAndSentenceMovedElsewhereAreNotRepeated() {
        let local = "# Notes\nFirst thought。Second thought。\nMoved paragraph。\nClosing"
        let remote = "# Notes\nMoved paragraph。\nSecond thought。First thought。\nNew thought。\nClosing"
        let result = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertEqual(occurrences("First thought。", in: result), 1)
        XCTAssertEqual(occurrences("Second thought。", in: result), 1)
        XCTAssertEqual(occurrences("Moved paragraph。", in: result), 1)
        XCTAssertEqual(occurrences("New thought。", in: result), 1)
        XCTAssertEqual(occurrences("Closing", in: result), 1)
    }

    func testSameListItemUnderDifferentHeadingsIsNotCollapsed() {
        let local = "# A\n- Shared item\n# B\n- Shared item"
        let remote = "# B\n- Shared item\n- Remote item"
        let result = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertEqual(occurrences("- Shared item", in: result), 2)
        XCTAssertEqual(occurrences("- Remote item", in: result), 1)
        XCTAssertLessThan(index(of: "# A", in: result), index(of: "# B", in: result))
    }

    func testRepeatsAlreadyInOneCopyRemain() {
        let local = "# Notes\nAgain。\nAgain。"
        let remote = "# Notes\nAgain。"
        let result = SyncMerge.combine(local: local, remote: remote).text
        XCTAssertEqual(occurrences("Again。", in: result), 2)
    }

    func testUnicodeAndMarkdownIndentationSurvive() {
        let local = "# 灵感 🏝️\n- café 👩🏽‍💻\n  - 子项\n结尾"
        let remote = "# 灵感 🏝️\n- café 👩🏽‍💻\n  - 新子项 🧑🏽‍💻\n结尾"
        let result = SyncMerge.combine(local: local, remote: remote).text

        // Distinct nested trees stay intact instead of silently reparenting a
        // child. Their shared parent label remains in each editable variant.
        XCTAssertEqual(occurrences("- café 👩🏽‍💻", in: result), 2)
        XCTAssertTrue(result.contains("- café 👩🏽‍💻\n  - 子项"))
        XCTAssertTrue(result.contains("- café 👩🏽‍💻\n  - 新子项 🧑🏽‍💻"))
        XCTAssertEqual(occurrences("结尾", in: result), 1)
    }

    func testIdenticalNestedTreeIsDeduplicatedAsAWhole() {
        let shared = "- Parent\n  - Child\n    Continuation"
        let result = SyncMerge.combine(local: "# Note\n" + shared + "\nLocal", remote: "# Note\n" + shared + "\nRemote").text
        XCTAssertEqual(occurrences(shared, in: result), 1)
        XCTAssertTrue(result.contains("Local")); XCTAssertTrue(result.contains("Remote"))
    }

    func testInlineMarkdownAndHardBreaksRemainWhole() {
        let local = "# Note\n**A。B。**\n[标签。内容。](https://example.com)\nA hard break  \nEnd"
        let remote = "# Note\n**A。C。**\n[标签。新内容。](https://example.com)\nA hard break  \nEnd"
        let result = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertTrue(result.contains("**A。B。**"))
        XCTAssertTrue(result.contains("**A。C。**"))
        XCTAssertTrue(result.contains("[标签。内容。](https://example.com)"))
        XCTAssertTrue(result.contains("[标签。新内容。](https://example.com)"))
        XCTAssertEqual(occurrences("A hard break  ", in: result), 1)
        XCTAssertEqual(occurrences("End", in: result), 1)
    }

    func testMergingAgainWithEitherSourceIsStable() {
        let local = "# A\nFirst。Second。\n# B\n- Shared"
        let remote = "# A\nSecond。First。Extra。\n# B\n- Shared\n- Remote"
        let merged = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertEqual(SyncMerge.combine(local: merged, remote: local).text, merged)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: remote).text, merged)
    }

    func testMovedHeadingDoesNotPutNewProseUnderTheWrongSection() {
        let local = "# A\nx\n# B\ny"
        let remote = "# B\ny\n# A\nz"
        let merged = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertTrue(merged.contains("# A\nz"))
        XCTAssertLessThan(index(of: "# B", in: merged), lastIndex(of: "# A", in: merged))
        XCTAssertEqual(occurrences("x", in: merged), 1)
        XCTAssertEqual(occurrences("y", in: merged), 1)
        XCTAssertEqual(occurrences("z", in: merged), 1)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: local).text, merged)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: remote).text, merged)
    }

    func testNestedHeadingReorderRestoresRemoteContext() {
        let local = "# Root\n## A\n### Topic\nold\n## B\n### Else\nstay"
        let remote = "# Root\n## B\n### Else\nstay\n## A\n### Topic\nnew"
        let merged = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertTrue(merged.contains("## A\n### Topic\nnew"))
        XCTAssertLessThan(index(of: "## B", in: merged), lastIndex(of: "## A", in: merged))
        XCTAssertEqual(occurrences("old", in: merged), 1)
        XCTAssertEqual(occurrences("stay", in: merged), 1)
        XCTAssertEqual(occurrences("new", in: merged), 1)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: local).text, merged)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: remote).text, merged)
    }

    func testLocalBodyAfterRestoredRemoteHeadingReturnsToItsOwnSection() {
        let local = "# A\nlocalA\n# B\nsameB"
        let remote = "# B\nremoteB\n# A\nnewA\n# B\nsameB"
        let merged = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertEqual(section(of: "localA", in: merged), ["# A"])
        XCTAssertEqual(section(of: "newA", in: merged), ["# A"])
        XCTAssertEqual(section(of: "sameB", in: merged), ["# B"])
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: local).text, merged)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: remote).text, merged)
    }

    func testEqualLocalBodyAfterRemoteHeadingKeepsItsSection() {
        let local = "# A\nx\n# B\ny\n# A\nlocalExtra"
        let remote = "# A\n# C\nc\n# A\nx\n# B\ny"
        let merged = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertEqual(section(of: "c", in: merged), ["# C"])
        XCTAssertEqual(section(of: "x", in: merged), ["# A"])
        XCTAssertEqual(section(of: "y", in: merged), ["# B"])
        XCTAssertEqual(section(of: "localExtra", in: merged), ["# A"])
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: local).text, merged)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: remote).text, merged)
    }

    func testNestedListTreesKeepTheirChildrenAfterInsertion() {
        let local = "- Parent\n  - Child\n- End"
        let remote = "- Parent\n- Other\n  - Child\n- End"
        let merged = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertTrue(merged.contains("- Parent\n  - Child"))
        XCTAssertTrue(merged.contains("- Other\n  - Child"))
        XCTAssertEqual(occurrences("- End", in: merged), 1)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: local).text, merged)
        XCTAssertEqual(SyncMerge.combine(local: merged, remote: remote).text, merged)
    }

    func testLongUnrelatedSectionsAreComplete() {
        let local = (0..<750).map { "Local \($0)" }.joined(separator: "\n")
        let remote = (0..<750).map { "Remote \($0)" }.joined(separator: "\n")
        let result = SyncMerge.combine(local: local, remote: remote).text

        XCTAssertTrue(result.hasPrefix("Local 0\n"))
        XCTAssertTrue(result.contains("Local 749"))
        XCTAssertTrue(result.contains("Remote 0"))
        XCTAssertTrue(result.hasSuffix("Remote 749"))
        XCTAssertEqual(occurrences("Local ", in: result), 750)
        XCTAssertEqual(occurrences("Remote ", in: result), 750)
    }

    private func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func index(of needle: String, in text: String) -> Int {
        guard let range = text.range(of: needle) else {
            XCTFail("Missing \(needle)")
            return Int.max
        }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private func lastIndex(of needle: String, in text: String) -> Int {
        guard let range = text.range(of: needle, options: .backwards) else {
            XCTFail("Missing \(needle)")
            return Int.max
        }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private func section(of exactLine: String, in text: String) -> [String]? {
        var headings = Array(repeating: "", count: 6)
        for line in text.components(separatedBy: "\n") {
            let level = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), line.dropFirst(level).first == " " {
                headings[level - 1] = line
                if level < 6 { for index in level..<6 { headings[index] = "" } }
            } else if line == exactLine {
                return headings.filter { !$0.isEmpty }
            }
        }
        return nil
    }
}
