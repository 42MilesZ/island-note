import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Structured list editing")
struct StructuredListsTests {
    private func editor(_ text: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        var config = MarkdownEditorConfiguration.default
        config.lists.structuredEditing = true
        config.lists.indentPerLevel = 24
        let c = NativeTextViewCoordinator(text: .constant(text), fontName: "SF Pro", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil)
        c.configuration = config
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        tv.configuration = config
        tv.isEditable = true
        tv.allowsUndo = true
        tv.delegate = c
        c.textView = tv
        c.rebuildTextStorageAndStyle(tv, from: text)
        c.lastSyncedText = text
        c.lastComputedStorage = text
        c.previousDisplayLength = text.utf16.count
        return (tv, c)
    }
    private func caret(_ text: String, _ needle: String) -> Int { (text as NSString).range(of: needle).location }

    @Test func tabMovesSubtreeAndRenumbersBothLevels() {
        let source = "1. 父项\n2. 第二项\n  1. 子项 🐈\n3. 最后"
        let (tv, c) = editor(source)
        tv.setSelectedRange(NSRange(location: caret(source, "第二项"), length: 0))
        tv.insertText("\t", replacementRange: tv.selectedRange())
        #expect(tv.string == "1. 父项\n  1. 第二项\n    1. 子项 🐈\n2. 最后")
        #expect((tv.string as NSString).substring(from: tv.selectedRange().location).hasPrefix("第二项"))
        withExtendedLifetime(c) {}
    }
    @Test func outdentMovesSubtreeAndSelection() {
        let source = "1. A\n  1. B\n    - child\n  2. C\n2. D"
        let (tv, c) = editor(source)
        let start = caret(source, "B"), end = caret(source, "C") + 1
        tv.setSelectedRange(NSRange(location: start, length: end - start))
        #expect(c.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(tv.string == "1. A\n2. B\n  - child\n3. C\n4. D")
        #expect((tv.string as NSString).substring(with: tv.selectedRange()).hasSuffix("C"))
    }
    @Test func enterAndDeletionKeepSourceNumbers() {
        let (tv, c) = editor("1. A\n2. B\n3. C")
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        #expect(tv.string == "1. A\n2. \n3. B\n4. C")
        let b = (tv.string as NSString).range(of: "3. B\n")
        tv.insertText("", replacementRange: b)
        #expect(tv.string == "1. A\n2. \n3. C")
        withExtendedLifetime(c) {}
    }
    @Test func emptyItemExitsOneLevelAtATime() {
        let (tv, c) = editor("1. A\n  1. ")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        #expect(tv.string == "1. A\n2. ")
        tv.insertText("\n", replacementRange: tv.selectedRange())
        #expect(tv.string == "1. A\n")
        withExtendedLifetime(c) {}
    }
    @Test func sharedDepthAndParentCounters() {
        let source = "1. A\n\t8. B\n  9. C\n2. D\n  7. E\n- X\n  8. F"
        let list = StructuredLists.items(source)
        let n = StructuredLists.numbers(list)
        #expect(list.compactMap { n[$0.marker.location] } == [1, 1, 2, 2, 1, 1])
    }
    @Test func codeAndUnrelatedGroupsArePreserved() {
        let source = "```\n7. code\n```\n9. old\n\nProse\n1. A\n7. B"
        let patches = StructuredLists.numberPatches(source, touching: (source as NSString).range(of: "7. B"))
        #expect(StructuredLists.replacing(source, patches: patches) == "```\n7. code\n```\n9. old\n\nProse\n1. A\n2. B")
        let (tv, c) = editor(source)
        tv.setSelectedRange(NSRange(location: caret(source, "code"), length: 0))
        #expect(!c.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    }
    @Test func taskContinuationResetsCheckboxAndKeepsDepth() {
        let (tv, c) = editor("- parent\n  - [x] 完成")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        #expect(tv.string == "- parent\n  - [x] 完成\n  - [ ] ")
        withExtendedLifetime(c) {}
    }
    @Test func oneUndoRestoresStructureAndNumbers() {
        let source = "1. A\n2. B\n  - child\n3. C"
        let (tv, c) = editor(source)
        let undo = c.undoManager(for: tv)!
        undo.removeAllActions()
        undo.beginUndoGrouping()
        tv.setSelectedRange(NSRange(location: caret(source, "B"), length: 0))
        tv.insertText("\t", replacementRange: tv.selectedRange())
        undo.endUndoGrouping()
        let changed = tv.string
        #expect(changed != source)
        undo.undo()
        #expect(tv.string == source)
        undo.redo()
        #expect(tv.string == changed)
    }
    @Test func depthMarkersAndHangingIndents() {
        var config = MarkdownEditorConfiguration.default
        config.lists.structuredEditing = true
        config.lists.indentPerLevel = 24
        let source = "- A\n  - B\n    - C\n\t- D"
        let attrs = MarkdownASTStyler.styleAttributes(text: source, fontName: "SF Pro", fontSize: 14,
            caretLocation: -1, configuration: config)
        #expect(attrs.compactMap { $0.1[.bulletMarker] as? String } == ["•", "◦", "▪", "◦"])
        let styles = attrs.compactMap { $0.1[.paragraphStyle] as? NSParagraphStyle }
        #expect(styles.map(\.firstLineHeadIndent) == [24, 48, 72, 48])
        #expect(styles.allSatisfy { $0.headIndent > $0.firstLineHeadIndent })
    }
    @Test func fourSpaceListsKeepTheirEstablishedUnit() {
        let source = "1. A\n    1. B\n    2. C\n2. D"
        let (tv, c) = editor(source)
        tv.setSelectedRange(NSRange(location: caret(source, "C"), length: 0))
        tv.insertText("\t", replacementRange: tv.selectedRange())
        #expect(tv.string == "1. A\n    1. B\n        1. C\n2. D")
        #expect(c.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(tv.string == source)
    }
    @Test func tabAndSpaceContentHaveTheSameActualPosition() throws {
        let source = "- root\n  - spaces\n\t- tabs\n    - deeper spaces\n\t\t- deeper tabs\n      - six spaces\n    \t- mixed tabs"
        let (tv, c) = editor(source)
        let layout = try #require(tv.textLayoutManager)
        let manager = try #require(layout.textContentManager)
        layout.ensureLayout(for: manager.documentRange)
        func x(_ needle: String) throws -> CGFloat {
            let loc = caret(source, needle)
            let start = try #require(manager.location(manager.documentRange.location, offsetBy: loc))
            let end = try #require(manager.location(start, offsetBy: 1))
            let range = try #require(NSTextRange(location: start, end: end))
            var result: CGFloat?
            layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
                result = rect.minX; return false
            }
            return try #require(result)
        }
        #expect(abs(try x("spaces") - x("tabs")) < 0.5)
        #expect(abs(try x("deeper spaces") - x("deeper tabs")) < 0.5)
        #expect(abs(try x("deeper spaces") - x("spaces") - 24) < 0.5)
        #expect(abs(try x("six spaces") - x("mixed tabs")) < 0.5)
        withExtendedLifetime(c) {}
    }
    @Test func compositionIsNotRenumberedAndContentSurvives() {
        let source = "1. A\n2. 中文 🐈"
        let (tv, c) = editor(source)
        let range = (source as NSString).range(of: "中文")
        tv.setSelectedRange(range)
        tv.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: range)
        #expect(tv.hasMarkedText())
        #expect(!StructuredLists.shift(tv, outdent: false))
        tv.insertText("中", replacementRange: tv.markedRange())
        #expect(tv.string == "1. A\n2. 中 🐈")
        withExtendedLifetime(c) {}
    }
    @Test func replacingEmojiDuringListPasteKeepsUTF16Valid() {
        let (tv, c) = editor("1. 🐈\n2. B")
        let range = (tv.string as NSString).range(of: "🐈")
        tv.insertText("🐕\n1. 新增", replacementRange: range)
        #expect(tv.string == "1. 🐕\n2. 新增\n3. B")
        withExtendedLifetime(c) {}
    }
    @Test func multiSelectionExcludesNextLineAtItsStart() {
        let source = "- A\n- B\n- C\n- D"
        let (tv, c) = editor(source)
        let start = caret(source, "- B"), end = caret(source, "- D")
        tv.setSelectedRange(NSRange(location: start, length: end - start))
        tv.insertText("\t", replacementRange: tv.selectedRange())
        #expect(tv.string == "- A\n  - B\n  - C\n- D")
        withExtendedLifetime(c) {}
    }

    @Test func indentedFencesNeverBecomeNumberedListItems() {
        for fence in ["```", "~~~"] {
            let source = "1. A\n  \(fence)\n  9. code\n  \(fence)\n2. B\n3. C"
            let (tv, c) = editor(source)
            tv.setSelectedRange(NSRange(location: caret(source, "B") + 1, length: 0))
            tv.insertText("\n", replacementRange: tv.selectedRange())
            #expect(tv.string == "1. A\n  \(fence)\n  9. code\n  \(fence)\n2. B\n3. \n4. C")
            tv.setSelectedRange(NSRange(location: caret(tv.string, "code") + 4, length: 0))
            tv.insertText("\n", replacementRange: tv.selectedRange())
            #expect(tv.string.contains("  9. code\n\n"))
            withExtendedLifetime(c) {}
        }
    }
    @Test func movingParentPreservesItsFencedContent() {
        let source = "1. A\n2. B\n  ```\n  9. code\n  ```\n3. C"
        let (tv, c) = editor(source)
        tv.setSelectedRange(NSRange(location: caret(source, "B"), length: 0))
        tv.insertText("\t", replacementRange: tv.selectedRange())
        #expect(tv.string == "1. A\n  1. B\n    ```\n    9. code\n    ```\n2. C")
        withExtendedLifetime(c) {}
    }
    @Test func selectionAcrossEmptyItemIsReplacedByEnter() {
        let source = "1. A\n2. \n3. B\n4. C"
        let (tv, c) = editor(source)
        let start = caret(source, "2. ") + 3
        let end = caret(source, "B") + 1
        tv.setSelectedRange(NSRange(location: start, length: end - start))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        #expect(!tv.string.contains("B"))
        #expect(tv.string == "1. A\n2. \n3. \n4. C")
        withExtendedLifetime(c) {}
    }
    @Test func insertionAcrossNineAndTenRenumbersSource() {
        let source = (1...11).map { "\($0). item \($0)" }.joined(separator: "\n")
        let (tv, c) = editor(source)
        let location = caret(source, "item 9") + "item 9".utf16.count
        tv.setSelectedRange(NSRange(location: location, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        #expect(tv.string.contains("9. item 9\n10. \n11. item 10\n12. item 11"))
        #expect(tv.selectedRange().location == caret(tv.string, "10. ") + 4)
        withExtendedLifetime(c) {}
    }

    @Test func indentDoesNotCreateOrphanAcrossSeparateLists() {
        let source = "- A\n- B\n\nParagraph\n\n- C"
        let (tv, c) = editor(source)
        let start = caret(source, "- B")
        tv.setSelectedRange(NSRange(location: start, length: source.utf16.count - start))
        tv.insertText("\t", replacementRange: tv.selectedRange())
        #expect(tv.string == source)
        withExtendedLifetime(c) {}
    }
    @Test func firstItemAndMaximumDepthDoNotMove() {
        for source in ["- first", "- A\n  - B\n    - C\n      - D"] {
            let (tv, c) = editor(source)
            tv.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            tv.insertText("\t", replacementRange: tv.selectedRange())
            #expect(tv.string == source)
            withExtendedLifetime(c) {}
        }
    }

}
