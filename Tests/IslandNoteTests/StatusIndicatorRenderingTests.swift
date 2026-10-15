import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class StatusIndicatorRenderingTests: XCTestCase {
    private func fixture() throws -> (NoteEditorView, StatusIndicatorButton, CATextLayer) {
        _ = NSApplication.shared
        let editor = NoteEditorView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        editor.motionIsReduced = { false }
        editor.showLocalSaveState(.saved)
        editor.setFlomoEnabled(true)
        editor.showSyncStatus(.verifyWrite, detail: "First detail")
        editor.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(editor.subviews.compactMap { $0 as? StatusIndicatorButton }.first)
        let label = try XCTUnwrap(button.layer?.sublayers?.compactMap { $0 as? CATextLayer }.first {
            $0.name == "sync-status-label"
        })
        return (editor, button, label)
    }

    func testStableStatusDuringResizeDoesNotRedrawOrRestartTransitions() throws {
        let (editor, button, label) = try fixture()
        let layers = [try XCTUnwrap(button.layer)] + (button.layer?.sublayers ?? [])
        for layer in layers { layer.removeAllAnimations(); layer.displayIfNeeded() }
        let initialFrame = label.frame
        for width in [680.0, 640, 600, 660] {
            editor.frame.size.width = width
            editor.layoutSubtreeIfNeeded()
            editor.showSyncStatus(.verifyWrite, detail: "Updated detail")
            XCTAssertEqual(label.frame, initialFrame)
            XCTAssertFalse(label.needsDisplay(), "Unchanged status text must not invalidate its backing store")
            for layer in layers { XCTAssertTrue((layer.animationKeys() ?? []).isEmpty) }
        }
        XCTAssertTrue(button.accessibilityHelp()?.contains("Updated detail") == true)
    }

    func testActualTextChangesAndWidthClampStillUpdateWithOriginalTiming() throws {
        let (editor, button, label) = try fixture()
        editor.showSyncStatus(.syncing, detail: "Syncing")
        XCTAssertEqual(label.string as? String, StatusPresentation(local: .saved, phase: .syncing,
                                                                 flomoEnabled: true).caption)
        let fade = try XCTUnwrap(label.animation(forKey: "opacity") as? CABasicAnimation)
        XCTAssertEqual(fade.duration, 0.16)
        XCTAssertEqual(fade.timingFunction, CAMediaTimingFunction(name: .easeInEaseOut))
        let oldWidth = label.frame.width
        editor.frame.size.width = 120
        editor.layoutSubtreeIfNeeded()
        editor.showSyncStatus(.syncing, detail: "Syncing again")
        XCTAssertLessThan(label.frame.width, oldWidth)
        let expansion = try XCTUnwrap(button.layer?.animation(forKey: "sync-expansion-bounds"))
        XCTAssertEqual(expansion.duration, 0.24)
        editor.showSyncStatus(.verifyWrite, detail: "Review")
        XCTAssertEqual(label.string as? String, StatusPresentation(local: .saved, phase: .verifyWrite,
                                                                 flomoEnabled: true).caption)
        XCTAssertEqual(label.opacity, 1)
    }

    func testHoverAndPressOnlyChangeAppearanceInBothLanguages() throws {
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.chinese, .english] {
            L10n.language = language
            let (editor, button, label) = try fixture()
            for phase in [SyncPhase.synced, .checking, .syncing, .waiting, .conflict, .verifyWrite, .connectionFailed] {
                editor.showSyncStatus(phase, detail: "Fixture details")
                editor.layoutSubtreeIfNeeded()
                for layer in [button.layer!, label] { layer.removeAllAnimations(); layer.displayIfNeeded() }
                let text = label.string as? String
                let frame = button.frame
                let labelFrame = label.frame
                let background = button.layer?.backgroundColor
                let outgoing = button.layer?.sublayers?.filter { $0.name == "sync-status-outgoing" }
                    .map(ObjectIdentifier.init)
                button.onHover?(true)
                XCTAssertEqual(label.string as? String, text)
                XCTAssertEqual(button.frame, frame)
                XCTAssertEqual(label.frame, labelFrame)
                XCTAssertNil(button.layer?.animation(forKey: "sync-expansion-bounds"))
                XCTAssertFalse(label.needsDisplay())
                XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0.18)
                let animation = try XCTUnwrap(button.layer?.animation(forKey: "backgroundColor") as? CABasicAnimation)
                XCTAssertEqual(animation.timingFunction, CAMediaTimingFunction(name: .easeInEaseOut))
                button.highlight(true)
                XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0.24)
                XCTAssertEqual(label.string as? String, text)
                button.highlight(false)
                button.onHover?(false)
                XCTAssertEqual(button.layer?.backgroundColor, background)
                XCTAssertEqual(button.frame, frame)
                XCTAssertFalse(button.accessibilityLabel()?.contains("Click") ?? true)
                XCTAssertFalse(button.accessibilityLabel()?.contains("点击") ?? true)
                XCTAssertEqual(button.layer?.sublayers?.filter { $0.name == "sync-status-outgoing" }
                    .map(ObjectIdentifier.init), outgoing, "Hover and press must not start a text transition")
            }
        }
    }
}
