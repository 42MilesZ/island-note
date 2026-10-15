import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class SyncMergePreviewTests: XCTestCase {
    func testPreviewIsEditableAndRejectsInvalidDraftUntilCorrected() throws {
        _ = NSApplication.shared
        let preview = SyncMergePreviewWindowController(text: "Shared\nLocal\nRemote")
        defer { preview.window?.close() }
        XCTAssertTrue(preview.textView.isEditable)
        XCTAssertTrue(preview.textView.allowsUndo)
        XCTAssertTrue(preview.applyButton.isEnabled)
        for invalid in ["", String(repeating: "长", count: 30_001), "- [ ] Unsupported task"] {
            preview.textView.string = invalid
            preview.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertFalse(preview.applyButton.isEnabled)
            XCTAssertNotEqual(preview.validationLabel.stringValue, L10n.tr("Originals are backed up before replacement."))
        }
        preview.textView.string = "Edited result 👨‍👩‍👧‍👦"
        preview.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertTrue(preview.applyButton.isEnabled)
    }

    func testCancelLeavesParentComparisonOpenWithoutChoosingACopy() async throws {
        _ = NSApplication.shared
        let comparison = FlomoConflictWindowController(conflict: SyncConflict(local: "Shared\nLocal", remote: FlomoMemo(id: "fixture", content: "Shared\nRemote", updatedAt: "v1")),
            phase: .verifyWrite, lastVerifiedAt: nil, canChoose: true,
            preparedComparison: SyncDiff.compare(left: "Shared\nLocal", right: "Shared\nRemote"))
        let interaction = Task { @MainActor in
            comparison.mergeButton.performClick(nil)
            let deadline = Date().addingTimeInterval(5)
            while comparison.mergePreview == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            guard let preview = comparison.mergePreview else { comparison.window?.close(); return XCTFail("Expected merge preview") }
            preview.textView.string = "Discard this draft"
            preview.cancelButton.performClick(nil)
            while comparison.mergePreview != nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(comparison.window?.isVisible ?? false)
            XCTAssertTrue(comparison.mergeButton.isEnabled)
            XCTAssertEqual((comparison.localScroll.documentView as? NSTextView)?.string, "Shared\nLocal")
            comparison.window?.close()
        }
        let choice = await comparison.run()
        await interaction.value
        XCTAssertNil(choice)
    }

    func testPreviewFitsBothLanguagesAndAppearancesWithLongText() throws {
        guard let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let original = L10n.language
        defer { L10n.language = original }
        let text = "# 项目记录\n\n共同段落只保留一次。\n\n- Island Note 独有的反馈\n- Flomo 独有的计划\n\n" + String(repeating: "更多记录：合并前可以继续编辑，保留两边不同的内容。\n", count: 600)
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            for dark in [false, true] {
                let preview = SyncMergePreviewWindowController(text: text)
                defer { preview.window?.close() }
                let window = try XCTUnwrap(preview.window)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: 600, height: 400))
                preview.showWindow(nil)
                let root = try XCTUnwrap(window.contentView)
                root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                for button in [preview.applyButton!, preview.cancelButton!] {
                    XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
                }
                XCTAssertTrue(preview.applyButton.isEnabled)
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let name = "merge-preview-\(language.rawValue)-\(dark ? "dark" : "light").png"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }

    func testClosingTheComparisonDismissesItsDraftWithoutApplyingIt() async {
        _ = NSApplication.shared
        let comparison = FlomoConflictWindowController(conflict: SyncConflict(local: "Local", remote: FlomoMemo(id: "fixture", content: "Remote", updatedAt: "v1")),
            phase: .verifyWrite, lastVerifiedAt: nil, canChoose: true,
            preparedComparison: SyncDiff.compare(left: "Local", right: "Remote"), savedMergeDraft: "Previously confirmed draft")
        let interaction = Task { @MainActor in
            comparison.mergeButton.performClick(nil)
            let deadline = Date().addingTimeInterval(5)
            while comparison.mergePreview == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            let preview = comparison.mergePreview
            XCTAssertEqual(preview?.textView.string, "Previously confirmed draft")
            comparison.window?.close()
            try? await Task.sleep(for: .milliseconds(60))
            XCTAssertFalse(preview?.window?.isVisible ?? true)
            XCTAssertNil(preview?.window?.sheetParent)
        }
        let choice = await comparison.run()
        await interaction.value
        XCTAssertNil(choice)
    }
}
