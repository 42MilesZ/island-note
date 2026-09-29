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

    func testBlankLinesAndEmptyDraftBulletsAreCosmetic() {
        let local = "First\n\n-\n- -\n*\n+\n1.\n2)\n\n- Real item\nLast"
        let remote = "First\n- Real item\n\n\nLast"
        XCTAssertTrue(SyncDocument.equivalent(local: local, remote: remote))
        for item in ["-", "- -", "*", "+", "1.", "2)", "  -", "\t1."] {
            XCTAssertEqual(SyncDocument.fromFlomo(SyncDocument.toFlomo(item)), item)
        }
        XCTAssertEqual(SyncDocument.toFlomo("  -"), "  \\-")
    }

    func testChangedMeaningStillDiffers() {
        XCTAssertFalse(SyncDocument.equivalent(local: "A plain line\nAnother line", remote: "A plain line\n\nChanged line"))
        XCTAssertFalse(SyncDocument.equivalent(local: "- Parent\n  - Child", remote: "- Parent\n- Child"))
        XCTAssertFalse(SyncDocument.equivalent(local: "## Heading", remote: "### Heading"))
        XCTAssertFalse(SyncDocument.equivalent(local: "**Bold**", remote: "Bold"))
        XCTAssertFalse(SyncDocument.equivalent(local: "- Important item", remote: ""))
    }

    func testWordInternalTildesSurviveRepeatedOutboundRoundTrips() {
        let local = "iCloud~md~obsidian and a~b"
        let encoded = "iCloud\\~md\\~obsidian and a\\~b"
        XCTAssertEqual(SyncDocument.toFlomo(local), encoded)
        XCTAssertEqual(SyncDocument.toFlomo(encoded), encoded)
        XCTAssertEqual(SyncDocument.fromFlomo(encoded), local)
        XCTAssertEqual(SyncDocument.toFlomo(SyncDocument.fromFlomo(encoded)), encoded)
        XCTAssertEqual(SyncDocument.toFlomo("~front a~~b end~"), "~front a~~b end~")
    }

    func testLegacyTildeLossRequiresOnlyMissingInternalTildes() {
        let local = "Heading\n\niCloud\\~md\\~obsidian\n- **Keep** text"
        let lost = "Heading\n\niCloudmdobsidian\n\n- **Keep** text"
        XCTAssertFalse(SyncDocument.equivalent(local: local, remote: lost))
        XCTAssertTrue(SyncDocument.isLegacyTransportLoss(local: local, remote: lost))
        XCTAssertFalse(SyncDocument.isLegacyTransportLoss(local: local, remote: "Heading\niCloudmdobsidian\n- Keep text"))
        XCTAssertFalse(SyncDocument.isLegacyTransportLoss(local: local, remote: "Heading\niCloud~md~obsidian\n- **Keep** text"))
        XCTAssertFalse(SyncDocument.isLegacyTransportLoss(local: "a~b", remote: "a~b"))
        XCTAssertFalse(SyncDocument.isLegacyTransportLoss(local: "a~b", remote: "aXb"))
    }

    func testOnlyExactAutolinkIsUnwrapped() {
        XCTAssertEqual(SyncDocument.fromFlomo("Go to [https://example.org/a](https://example.org/a)"), "Go to https://example.org/a")
        let authoredLink = "Go to [the site](https://example.org/a)"
        XCTAssertEqual(SyncDocument.fromFlomo(authoredLink), authoredLink)
        XCTAssertNotNil(SyncDocument.issue(in: authoredLink))
        XCTAssertNil(SyncDocument.issue(in: SyncDocument.fromFlomo("Go to [https://example.org/a](https://example.org/a)")))
    }
}
