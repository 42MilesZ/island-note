import XCTest
@testable import IslandNote

final class SyncInlineFormatTests: XCTestCase {
    func testBoldSpellingsAndNestedHTMLHaveOneStyleKey() {
        assertEquivalent("**重要**", "__重要__")
        assertEquivalent("**重要**", "<strong>重要</strong>")
        assertEquivalent("**重要**", "<b>重要</b>")
        assertEquivalent("<u><mark><b>重要</b></mark></u>", "<strong><u><mark>重要</mark></u></strong>")
        assertEquivalent("<b>A<strong>B</strong>C</b>", "**ABC**")
        assertEquivalent("A **bold** B", "A <STRONG>bold</STRONG> B")
        assertEquivalent("a**b**c", "a<b>b</b>c")
    }

    func testWordsStylesOrderAndSpacingRemainSignificant() {
        assertDifferent("**Bold**", "Bold")
        assertDifferent("<mark>Text</mark>", "<u>Text</u>")
        assertDifferent("**first** second", "first **second**")
        assertDifferent("A B", "A  B")
        assertDifferent("A B", "AB")
        assertDifferent("A B", "B A")
        assertDifferent("A B", "A\u{00A0}B")
        assertDifferent("🏝️", "🏝")
    }

    func testEscapesAndEntitiesRemainLiteralDuringParsing() {
        assertEquivalent(#"\*\*bold\*\*"#, "&#42;&#42;bold&#42;&#42;")
        assertDifferent(#"\*\*bold\*\*"#, "**bold**")
        assertEquivalent(#"\<b>bold\</b>"#, "&lt;b&gt;bold&lt;/b&gt;")
        assertDifferent("&lt;b&gt;bold&lt;/b&gt;", "<b>bold</b>")
        assertEquivalent("a__b__c", #"a\_\_b\_\_c"#)
        assertEquivalent("A &amp; B &#x1F3DD;&#65039;", "A & B 🏝️")
        assertEquivalent(##"\# literal \+ and 1\. item"##, "# literal + and 1. item")
        assertDifferent("&amp;lt;b&amp;gt;", "&lt;b&gt;")
        // Decoding is one pass; a decoded ampersand is not a new entity.
        XCTAssertEqual(SyncInlineFormat.decodeEntities("&amp;lt;b&amp;gt;"), "&lt;b&gt;")
        XCTAssertEqual(SyncInlineFormat.decodeEntities("&eacute; &NotEqualTilde;"), "é ≂̸")
        assertEquivalent("&eacute; &NotEqualTilde;", "é ≂̸")
    }

    func testUnknownAndMalformedSyntaxDeclinesCanonicalization() {
        for source in ["**unclosed", "***italic and bold***", "_italic_", "*italic*", "~~strike~~", "`code`",
                       "<b>unclosed", "<b><u>crossed</b></u>", "<b style='color:red'>x</b>",
                       "<script>x</script>", "<br>", "one\ntwo", "**one <u>two** three</u>"] {
            XCTAssertNil(SyncInlineFormat.canonical(source), source)
        }
        XCTAssertEqual(SyncInlineFormat.decodeEntities("&unknown; &#0; &#xD800; &#x110000; &#128;"),
                       "&unknown; &#0; &#xD800; &#x110000; &#128;")
    }

    func testJSONKeysCannotCollideWithAuthoredTokenText() {
        assertDifferent("**x**", #"[[1,"x"]]"#)
        assertEquivalent("<b>x</b><strong>y</strong>", "**xy**")
        XCTAssertNotNil(SyncInlineFormat.canonical(""))
    }

    func testHTMLEncodingPreservesGapsInsideAdjacentStyleNodes() {
        XCTAssertEqual(SyncInlineFormat.html("<mark>A</mark> <u>B</u>"), "<mark>A&nbsp;</mark><u>B</u>")
        XCTAssertEqual(SyncInlineFormat.html("<mark>A</mark>  <u>B</u>"), "<mark>A&nbsp;&nbsp;</mark><u>B</u>")
        XCTAssertEqual(SyncInlineFormat.html(" <mark>A</mark> "), "<mark>&nbsp;A&nbsp;</mark>")
        XCTAssertEqual(SyncInlineFormat.html("<mark>A</mark>\t<u>B</u>"), "<mark>A&#9;</mark><u>B</u>")
        XCTAssertEqual(SyncInlineFormat.html("__A &amp; B__"), "<strong>A&nbsp;&amp;&nbsp;B</strong>")
        XCTAssertEqual(SyncInlineFormat.html("&lt;b&gt;literal&lt;/b&gt;"), "&lt;b&gt;literal&lt;/b&gt;")
        XCTAssertEqual(SyncInlineFormat.html("&amp;lt;"), "&amp;lt;")
        XCTAssertEqual(SyncInlineFormat.html("**First\nSecond**"), "<strong>First\nSecond</strong>")
        XCTAssertEqual(SyncInlineFormat.html(#"<mark>\*\*literal\*\*</mark> <u>B</u>"#),
                       "<mark>&#42;&#42;literal&#42;&#42;&nbsp;</mark><u>B</u>")
        XCTAssertEqual(SyncInlineFormat.html(#"\*\*literal\*\*"#), "&#42;&#42;literal&#42;&#42;")
        XCTAssertEqual(SyncInlineFormat.html(##"\_\`\~\[\]\#\\"##), "&#95;&#96;&#126;&#91;&#93;&#35;&#92;")
        XCTAssertNil(SyncInlineFormat.html("<script>x</script>"))
        XCTAssertNil(SyncInlineFormat.html("**unclosed"))
    }

    func testBorrowedWhitespaceStyleDoesNotChangeComparisonKeys() {
        assertEquivalent("<mark>A</mark> <u>B</u>", "<mark>A </mark><u>B</u>")
        assertEquivalent("<mark>A</mark> <u>B</u>", "<mark>A</mark><u> B</u>")
        assertEquivalent("<mark>A</mark>\t<u>B</u>", "<mark>A&#9;</mark><u>B</u>")
        assertDifferent("<mark>A</mark> <u>B</u>", "<mark>A</mark><u>B</u>")
        assertDifferent("<mark>A</mark>  <u>B</u>", "<mark>A </mark><u>B</u>")
        let source = "<mark>A</mark> <u>B</u>"
        let encoded = SyncInlineFormat.html(source)!
        XCTAssertEqual(SyncInlineFormat.canonical(source), SyncInlineFormat.canonical(encoded, normalizeNonBreakingSpaces: true))
        XCTAssertEqual(SyncInlineFormat.canonicalLines("<mark>A </mark>\n<u>B</u>"),
                       SyncInlineFormat.canonicalLines("<mark>A</mark> \n<u>B</u>"))
    }

    private func assertEquivalent(_ left: String, _ right: String, file: StaticString = #filePath, line: UInt = #line) {
        let leftKey = SyncInlineFormat.canonical(left)
        let rightKey = SyncInlineFormat.canonical(right)
        XCTAssertNotNil(leftKey, left, file: file, line: line)
        XCTAssertNotNil(rightKey, right, file: file, line: line)
        XCTAssertEqual(leftKey, rightKey, file: file, line: line)
    }

    private func assertDifferent(_ left: String, _ right: String, file: StaticString = #filePath, line: UInt = #line) {
        let leftKey = SyncInlineFormat.canonical(left)
        let rightKey = SyncInlineFormat.canonical(right)
        XCTAssertNotNil(leftKey, left, file: file, line: line)
        XCTAssertNotNil(rightKey, right, file: file, line: line)
        XCTAssertNotEqual(leftKey, rightKey, file: file, line: line)
    }
}
