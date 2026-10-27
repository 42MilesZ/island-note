import XCTest
@testable import IslandNote

final class SyncFormatMatrixTests: XCTestCase {
    // Synthetic readbacks captured from Flomo on 2026-10-27. No personal notes.
    static let supported: [(String, String, String)] = [
        ("bold", "**加粗** and __bold__", "**加粗** and **bold**"),
        ("nested styles", "<mark>**反向组合**</mark>", "<mark><strong>反向组合</strong></mark>"),
        ("bullets", "* 星号\n* 第二项\n\n+ 加号\n+ 第二项", "- 星号\n- 第二项\n\n- 加号\n- 第二项"),
        ("ordered delimiters", "1) 第一项\n2) 第二项", "1. 第一项\n2. 第二项"),
        ("nesting", "- 父项\n    - 子项\n        - 孙项\n- 尾项", "- 父项\n  - 子项\n    - 孙项\n- 尾项"),
        ("marker spaces", "-   多空格\n1.   有序空格", "- 多空格\n\n1. 有序空格"),
        ("breaks", "第一行  \n第二行\\\n第三行<br>第四行", "第一行<br>\n第二行<br>\n第三行<br>第四行"),
        ("entities", "A &amp; B &lt; C &gt; D &quot;Q&quot; &#39;S&#39; &nbsp; &#x4E2D;", "A & B < C > D \"Q\" 'S' \u{00a0} 中"),
        ("escapes", ##"\*literal\* \_under\_ \[brackets\] \#tag 1\. literal A \+ B a\-b path\\file"##,
         #"\*literal\* \_under\_ \[brackets\] #tag 1. literal A + B a-b path\\file"#),
        ("URLs", "https://example.org/a_(b)?x=1&y=2\nhttps://example.org/path#fragment",
         "<a href=\"https://example.org/a_(b)?x=1&amp;y=2\" rel=\"nofollow\">https://example.org/a_(b)?x=1&amp;y=2</a><br>[https://example.org/path#fragment](https://example.org/path#fragment)"),
        ("headings", "# 一级\n### 三级\n  ## 缩进标题", "\\# 一级<br>\n\\### 三级<br>\n\\## 缩进标题"),
        ("protected spacing", "A  B\n<mark>A</mark> <u>B</u>", "A \u{00a0}B<br><mark>A\u{00a0}</mark><u>B</u>"),
        ("style combinations", "**<mark><u>ABC</u></mark>**\n<mark>**Bold**</mark>\n__bold__", "**<mark><u>ABC</u></mark>**<br><mark><strong>Bold</strong></mark><br>**bold**"),
        ("multiline bold", "**First\nSecond**", "**First<br>**\n**Second**")
    ]

    func testCapturedSupportedReadbacks() {
        for (name, local, raw) in Self.supported {
            XCTAssertTrue(SyncDocument.matchesReadback(local: local, remote: SyncDocument.fromFlomo(raw)), name)
        }
    }

    func testComposedReadbacksAndActualChangesRemainDistinct() {
        let local = Self.supported.map { "CASE " + $0.0 + "\n\n" + $0.1 }.joined(separator: "\n\n")
        let remote = Self.supported.map { "CASE " + $0.0 + "\n\n" + $0.2 }.joined(separator: "\n\n")
        XCTAssertTrue(SyncDocument.matchesReadback(local: local, remote: SyncDocument.fromFlomo(remote)))
        for (_, source, raw) in Self.supported {
            XCTAssertFalse(SyncDocument.matchesReadback(local: source + "\nActual new text", remote: SyncDocument.fromFlomo(raw)))
            XCTAssertFalse(SyncDocument.matchesReadback(local: source, remote: SyncDocument.fromFlomo(raw) + "\nActual remote edit"))
        }
    }

    func testLostMeaningIsNotAFormattingAlias() {
        let pairs = [
            ("3. 第三项\n4. 第四项", "1. 第三项\n2. 第四项"),
            ("<mark>A</mark> <u>B</u>", "<mark>A</mark><u>B</u>"),
            ("A  B", "A B"), ("A B", "AB"), ("A<br>B", "AB"),
            ("**Bold**", "Bold"), ("<u>Word</u>", "<mark>Word</mark>"),
            ("- Parent\n  - Child", "- Parent\n- Child"),
            ("- Parent\n  - Child", "  - Child\n- Parent"),
            ("## Heading", "### Heading"),
            (#"\**literal\**"#, "**literal**"),
            ("[https://good.org](https://evil.org)", "https://good.org"),
            ("<a href=\"https://evil.org\" rel=\"nofollow\">https://good.org</a>", "https://good.org")
        ]
        for (local, remote) in pairs {
            XCTAssertFalse(SyncDocument.matchesReadback(local: local, remote: SyncDocument.fromFlomo(remote)), local)
        }
    }

    func testOutboundStabilizesListsSpacesAndIndentedHeadings() {
        XCTAssertEqual(SyncDocument.toFlomo("* Parent\n    + Child\n        - Grandchild"), "- Parent\n  - Child\n    - Grandchild")
        XCTAssertEqual(SyncDocument.toFlomo("A  B"), "A &nbsp;B")
        XCTAssertEqual(SyncDocument.toFlomo("<mark>A</mark> <u>B</u>"), "<mark>A&nbsp;</mark><u>B</u>")
        XCTAssertEqual(SyncDocument.toFlomo("  ## Heading"), "\\## Heading")
        XCTAssertEqual(SyncDocument.toFlomo("1) First\n2) Second"), "1. First\n2. Second")
        let hugeNumber = "9999999999999999999999999999. Literal"
        XCTAssertEqual(SyncDocument.toFlomo(hugeNumber), hugeNumber)
    }

    func testKnownLossySyntaxStopsBeforeUpload() {
        for text in ["3. Third\n4. Fourth", "1. First\n3. Third", "~~deleted~~", "`code`", "*italic*", "_italic_", "***bold italic***", "___bold italic___", "<div>text</div>", "Title\n===", "---", "- - -"] {
            XCTAssertNotNil(SyncDocument.issue(in: text), text)
        }
        for text in ["1. First\n2. Second", "<mark>**Bold**</mark>", "A &amp; B", "a__b__c", "2 * 3"] {
            XCTAssertNil(SyncDocument.issue(in: text), text)
        }
    }

    func testIrregularIndentationIsNotInventedAsAnExtraLevel() {
        let source = "- Parent\n  - Child\n   - Sibling"
        let invented = "- Parent\n  - Child\n    - Sibling"
        XCTAssertEqual(SyncDocument.toFlomo(source), source)
        XCTAssertNotNil(SyncDocument.issue(in: source))
        XCTAssertFalse(SyncDocument.matchesReadback(local: source, remote: invented))
        XCTAssertNotNil(SyncDocument.issue(in: "- Parent\n      - Child"))
    }

    func testCompatibleReadbackDoesNotEraseSourceSideEdits() {
        let baseline = "First\nSecond"
        let remote = "First<br>Second"
        let edited = "First  \nSecond"
        XCTAssertTrue(SyncDocument.matchesReadback(local: edited, remote: remote))
        XCTAssertEqual(SyncComparison.direction(baseline: baseline, remoteBaseline: remote, local: edited, remote: remote), .push)
        XCTAssertEqual(SyncComparison.direction(baseline: baseline, remoteBaseline: remote, local: edited, remote: "Changed<br>Second"), .conflict)
    }

    func testURLParenthesesAndQueryAreUnwrappedOnlyForExactLabels() {
        let url = "https://example.org/a_(b)?x=1&y=2"
        XCTAssertEqual(SyncDocument.fromFlomo("[\(url)](\(url))"), url)
        XCTAssertEqual(SyncDocument.fromFlomo("<a href=\"https://example.org/a_(b)?x=1&amp;y=2\" rel=\"nofollow\">https://example.org/a_(b)?x=1&amp;y=2</a>"), url)
        XCTAssertEqual(SyncDocument.fromFlomo("[label](\(url))"), "[label](\(url))")
        XCTAssertNotNil(SyncDocument.issue(in: "<a href=\"https://evil.org\">https://good.org</a>"))
    }
}
