import XCTest
@testable import IslandNote

final class DocumentHeadingTests: XCTestCase {
    func testLevelsFormattingAndDuplicateTitles() {
        let headings = DocumentHeading.parse("# **Overview**\n\n## [Details](https://example.com)\n\n###### `Code`\n\n# Overview\n")
        XCTAssertEqual(headings.map(\.level), [1, 2, 6, 1])
        XCTAssertEqual(headings.map(\.title), ["Overview", "Details", "Code", "Overview"])
        XCTAssertEqual(Set(headings.map(\.id)).count, 4)
    }

    func testCodeAndEscapedMarkersAreNotHeadings() {
        let source = "# Real\n\n```md\n# Fenced\n```\n\n~~~\n## Tildes\n~~~\n\n    # Indented\n\n\\# Escaped\n\n#NoSpace\n\n####### TooMany\n"
        XCTAssertEqual(DocumentHeading.parse(source).map(\.title), ["Real"])
        XCTAssertEqual(DocumentHeading.parse("# Real\n\n```\n## Still code\n").count, 1)
    }

    func testUnicodeAndCRLFOffsetsMatchTextStorage() {
        let source = "👩🏽‍💻 前言\r\n\r\n# 中文 🏝️\r\n\r\n## End\r\n"
        let headings = DocumentHeading.parse(source)
        let ns = source as NSString
        XCTAssertEqual(headings.map(\.title), ["中文 🏝️", "End"])
        XCTAssertEqual(headings.map(\.offset), [ns.range(of: "# 中文").location, ns.range(of: "## End").location])
    }

    func testSetextAndInlineRunsRemainOneHeading() {
        let source = "A **bold** and [linked](https://example.com) title\n===\n\nSecond\n---\n"
        XCTAssertEqual(DocumentHeading.parse(source).map(\.title), ["A bold and linked title", "Second"])
        XCTAssertEqual(DocumentHeading.parse(source).map(\.level), [1, 2])
    }

    func testVisibilityThresholdAndSourceEdits() {
        let model = HeadingOutlineModel()
        model.headings = DocumentHeading.parse("# One\n\n## Two\n")
        XCTAssertFalse(model.isVisible)
        model.headings = DocumentHeading.parse("# One\n\n## Two\n\n### Three\n")
        XCTAssertTrue(model.isVisible)
        model.headings = DocumentHeading.parse("# One\n")
        XCTAssertFalse(model.isVisible)
    }
}
