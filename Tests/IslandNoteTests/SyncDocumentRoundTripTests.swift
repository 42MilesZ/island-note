import XCTest
@testable import IslandNote

final class SyncDocumentRoundTripTests: XCTestCase {
    func testKnownFlomoFormattingIsEquivalentWithoutChangingLocalText() {
        let local = """
        ### Project
        - Parent
        \t- Nested item

        A plain line
        Another plain line

        - -

        - **Bold**-continuation- **Next** https://example.org/a
        iCloud\\~md\\~obsidian
        """
        let readback = """
        \\### Project

        - Parent
          - Nested item

        A plain line

        Another plain line

        \\- -

        - **Bold**\\-continuation\\- **Next** [https://example.org/a](https://example.org/a)
        iCloud~md~obsidian
        """
        XCTAssertEqual(SyncDocument.toFlomo("- -"), "\\- -")
        XCTAssertEqual(SyncDocument.fromFlomo("\\- -"), "- -")
        XCTAssertTrue(SyncDocument.equivalent(local: local, remote: SyncDocument.fromFlomo(readback)))
        XCTAssertTrue(local.contains("\t- Nested item"))
        XCTAssertTrue(local.contains("iCloud\\~md\\~obsidian"))
    }

    func testMissingPlaceholderAndChangedTextRemainDifferences() {
        XCTAssertFalse(SyncDocument.equivalent(local: "First\n- -\nLast", remote: "First\nLast"))
        XCTAssertFalse(SyncDocument.equivalent(local: "A plain line\nAnother line", remote: "A plain line\n\nChanged line"))
        XCTAssertFalse(SyncDocument.equivalent(local: "A paragraph\n\nAnother paragraph", remote: "A paragraph\nAnother paragraph"))
    }

    func testOnlyExactAutolinkIsUnwrapped() {
        XCTAssertEqual(SyncDocument.fromFlomo("Go to [https://example.org/a](https://example.org/a)"), "Go to https://example.org/a")
        let authoredLink = "Go to [the site](https://example.org/a)"
        XCTAssertEqual(SyncDocument.fromFlomo(authoredLink), authoredLink)
        XCTAssertNotNil(SyncDocument.issue(in: authoredLink))
        XCTAssertNil(SyncDocument.issue(in: SyncDocument.fromFlomo("Go to [https://example.org/a](https://example.org/a)")))
    }
}
