import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class FloatingResizeTests: XCTestCase {
    private let source = "# Floating note\n\nKeep this paragraph, its selection and its font while resizing.\n\n## Next steps\n\n- Drag a corner\n- Return to the island\n"
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.compactMap { find(type, in: $0) }.first
    }
    private func settle(_ interval: TimeInterval = 0.45) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
    private func withPanel(diagnostics: InteractionDiagnostics? = nil, openingDelay: TimeInterval = 1.1,
                           _ body: (IslandNoteController, IslandPanel, NoteEditorView, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-resize-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("fixture.md")
        try source.write(to: note, atomically: true, encoding: .utf8)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let controller = IslandNoteController(store: NoteStore(fileURL: note), enableSync: false, diagnostics: diagnostics)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? IslandPanel }.first { !existing.contains(ObjectIdentifier($0)) })
        defer { panel.close() }
        controller.expand()
        settle(openingDelay)
        let editor = try XCTUnwrap(find(NoteEditorView.self, in: try XCTUnwrap(panel.contentView)))
        let text = try XCTUnwrap(find(NSTextView.self, in: editor))
        try body(controller, panel, editor, text)
        controller.collapse()
        settle(1.1)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), source)
    }
    private func screenRect(_ panel: NSPanel, _ editor: NSView) -> NSRect {
        editor.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }
    private func header(_ panel: NSPanel, _ editor: NSView) -> NSPoint {
        let rect = screenRect(panel, editor)
        return NSPoint(x: rect.midX, y: rect.maxY - PanelDocking.headerInset)
    }
    private func pinch(_ controller: IslandNoteController, editor: NSView, delta: CGFloat) {
        let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
        XCTAssertTrue(controller.handleMagnification(delta: delta, phase: .began, locationInWindow: location))
        XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
    }
    private func snapshot(_ editor: NoteEditorView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] else { return }
        editor.wantsLayer = true
        editor.layer?.backgroundColor = NSColor.black.cgColor
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    func testFloatingMorphEdgesCustomPinchAndSizeRecall() throws {
        try withPanel { controller, panel, editor, text in
            text.setSelectedRange(NSRange(location: 24, length: 9))
            let selection = text.selectedRange()
            let font = try XCTUnwrap(text.textStorage?.attribute(.font, at: 24, effectiveRange: nil) as? NSFont)
            let home = panel.frame.origin
            let original = screenRect(panel, editor)
            let start = NSPoint(x: original.minX + 36, y: original.maxY - PanelDocking.headerInset)
            let release = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start)
            editor.dragHandle.onMove?(release)
            settle(0.12)
            XCTAssertLessThan(editor.frame.width, original.width)
            XCTAssertGreaterThan(editor.frame.height, original.height)
            let intermediate = screenRect(panel, editor)
            XCTAssertEqual(intermediate.minX + intermediate.width * 36 / original.width, release.x, accuracy: 1)
            XCTAssertEqual(intermediate.maxY - PanelDocking.headerInset, release.y, accuracy: 1)
            editor.dragHandle.onEnd?(release)
            settle()
            XCTAssertEqual(editor.frame.size, PanelSize.standard.floatingDimensions)
            XCTAssertEqual(panel.level, .floating)
            try snapshot(editor, name: "floating-default")

            let before = screenRect(panel, editor)
            var mouse = NSPoint(x: before.maxX, y: before.midY)
            controller.beginEdgeResize(edges: .right, at: mouse)
            mouse.x += 100
            controller.endEdgeResize(at: mouse)
            let wider = screenRect(panel, editor)
            XCTAssertEqual(wider.width, 520, accuracy: 0.1)
            XCTAssertEqual(wider.minX, before.minX, accuracy: 0.1)
            XCTAssertEqual(wider.maxY, before.maxY, accuracy: 0.1)
            mouse = NSPoint(x: wider.midX, y: wider.minY)
            controller.beginEdgeResize(edges: .bottom, at: mouse)
            mouse.y -= 80
            controller.endEdgeResize(at: mouse)
            let taller = screenRect(panel, editor)
            XCTAssertEqual(taller.height, 540, accuracy: 0.1)
            XCTAssertEqual(taller.maxY, wider.maxY, accuracy: 0.1)
            mouse = NSPoint(x: taller.minX, y: taller.maxY)
            controller.beginEdgeResize(edges: [.left, .top], at: mouse)
            mouse.x -= 40; mouse.y += 60
            controller.endEdgeResize(at: mouse)
            let corner = screenRect(panel, editor)
            XCTAssertEqual(corner.size, NSSize(width: 560, height: 600))
            XCTAssertEqual(corner.maxX, taller.maxX, accuracy: 0.1)
            XCTAssertEqual(corner.minY, taller.minY, accuracy: 0.1)
            pinch(controller, editor: editor, delta: -0.1)
            settle()
            let custom = editor.frame.size
            XCTAssertEqual(custom.width, 504, accuracy: 0.1)
            XCTAssertEqual(custom.height, 540, accuracy: 0.1)
            try snapshot(editor, name: "floating-custom")
            XCTAssertEqual(text.string, source)
            XCTAssertEqual(text.selectedRange(), selection)
            XCTAssertEqual((text.textStorage?.attribute(.font, at: 24, effectiveRange: nil) as? NSFont)?.pointSize, font.pointSize)

            let returnStart = header(panel, editor)
            let dockPoint = NSPoint(x: original.midX, y: original.maxY - PanelDocking.headerInset)
            editor.dragHandle.onBegin?(returnStart)
            editor.dragHandle.onMove?(dockPoint)
            editor.dragHandle.onEnd?(dockPoint)
            settle(0.7)
            XCTAssertEqual(panel.frame.origin, home)
            XCTAssertEqual(editor.frame.size, PanelSize.standard.dimensions)
            let out = NSPoint(x: dockPoint.x + 80, y: dockPoint.y - 170)
            editor.dragHandle.onBegin?(dockPoint)
            editor.dragHandle.onMove?(out)
            editor.dragHandle.onEnd?(out)
            settle()
            XCTAssertEqual(editor.frame.size.width, custom.width, accuracy: 0.1)
            XCTAssertEqual(editor.frame.size.height, custom.height, accuracy: 0.1)
        }
    }

    func testStationaryHeaderGrabDoesNotFreezeOrJumpSizeAnimation() throws {
        try withPanel { controller, panel, editor, _ in
            pinch(controller, editor: editor, delta: 0.1)
            settle(0.1)
            let clicked = header(panel, editor)
            editor.dragHandle.onBegin?(clicked)
            editor.dragHandle.onEnd?(clicked)
            settle()
            XCTAssertEqual(editor.frame.size, PanelSize.large.dimensions)
            let start = header(panel, editor)
            let release = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start)
            editor.dragHandle.onMove?(release)
            editor.dragHandle.onEnd?(release)
            // The return flight is over, but the floating aspect morph is still active.
            settle(0.27)
            let before = screenRect(panel, editor)
            let grip = NSPoint(x: before.minX + before.width * 0.15, y: before.maxY - PanelDocking.headerInset)
            editor.dragHandle.onBegin?(grip)
            settle(0.15)
            let held = screenRect(panel, editor)
            // NSPanel aligns its origin to backing pixels while the size is continuous.
            XCTAssertEqual(held.minX + held.width * 0.15, grip.x, accuracy: 1)
            XCTAssertEqual(held.maxY - PanelDocking.headerInset, grip.y, accuracy: 1)
            let moved = NSPoint(x: grip.x + 8, y: grip.y - 8)
            editor.dragHandle.onMove?(moved)
            let after = screenRect(panel, editor)
            XCTAssertEqual(after.minX + after.width * 0.15, moved.x, accuracy: 1)
            XCTAssertEqual(after.maxY - PanelDocking.headerInset, moved.y, accuracy: 1)
            editor.dragHandle.onEnd?(moved)
            settle()
            XCTAssertEqual(editor.frame.size, PanelSize.large.floatingDimensions)
        }
    }

    func testPinchDuringDockingIsQueuedAndCompletesWithDiagnosticEvidence() throws {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        try withPanel(diagnostics: diagnostics) { controller, panel, editor, _ in
            let dockPoint = header(panel, editor)
            let release = NSPoint(x: dockPoint.x + 80, y: dockPoint.y - 170)
            editor.dragHandle.onBegin?(dockPoint)
            editor.dragHandle.onMove?(release)
            editor.dragHandle.onEnd?(release)
            settle()
            let returnStart = header(panel, editor)
            editor.dragHandle.onBegin?(returnStart)
            editor.dragHandle.onMove?(dockPoint)
            editor.dragHandle.onEnd?(dockPoint)
            pinch(controller, editor: editor, delta: 0.1)
            XCTAssertTrue(diagnostics.events.contains { $0.reason == .resizeQueued && $0.state.docking })
            settle(0.8)
            XCTAssertEqual(panel.level, .screenSaver)
            XCTAssertEqual(editor.frame.size, PanelSize.large.dimensions)
            XCTAssertTrue(diagnostics.events.contains { $0.reason == .resizeCompleted && $0.state.width == 690 })
            // An endpoint no-op and a rejected origin leave different evidence.
            pinch(controller, editor: editor, delta: 0.1)
            XCTAssertTrue(diagnostics.events.contains { $0.reason == .presetLimit })
            XCTAssertFalse(controller.handleMagnification(delta: 0.1, phase: .began, locationInWindow: NSPoint(x: -1000, y: -1000)))
            XCTAssertEqual(diagnostics.events.last?.reason, .outsidePanel)
        }
    }

    func testPinchUsesEditorFootprintWhileOpeningContourIsAnimating() throws {
        try withPanel(openingDelay: 0.03) { controller, _, editor, _ in
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.minY + 30)
            XCTAssertTrue(controller.handleMagnification(delta: 0.1, phase: .began, locationInWindow: location))
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
            settle()
            XCTAssertEqual(editor.frame.size, PanelSize.large.dimensions)
        }
    }

    func testFloatingPinchFollowsEveryDeltaWithStableCenterAndReversibleLimits() throws {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        try withPanel(diagnostics: diagnostics) { controller, panel, editor, text in
            let start = header(panel, editor)
            let release = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start)
            editor.dragHandle.onMove?(release)
            editor.dragHandle.onEnd?(release)
            settle()
            let initial = screenRect(panel, editor)
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .began, locationInWindow: location))
            var size = initial.size
            for delta: CGFloat in [0.01, 0.015, 0.02, 0.01, -0.03] {
                XCTAssertTrue(controller.handleMagnification(delta: delta, phase: .changed, locationInWindow: location))
                size.width *= 1 + delta; size.height *= 1 + delta
                XCTAssertEqual(editor.frame.width, size.width, accuracy: 0.001)
                XCTAssertEqual(editor.frame.height, size.height, accuracy: 0.001)
                let visible = screenRect(panel, editor)
                XCTAssertEqual(visible.midX, initial.midX, accuracy: 1)
                XCTAssertEqual(visible.midY, initial.midY, accuracy: 1)
            }
            // Continue within the same gesture past the old large preset, then reverse.
            XCTAssertTrue(controller.handleMagnification(delta: 100, phase: .changed, locationInWindow: location))
            let screen = try XCTUnwrap(panel.screen).visibleFrame
            let largest = screenRect(panel, editor)
            XCTAssertLessThanOrEqual(largest.width, min(1200, screen.width) + 1)
            XCTAssertLessThanOrEqual(largest.height, min(1000, screen.height) + 1)
            XCTAssertGreaterThanOrEqual(largest.minX, screen.minX - 1)
            XCTAssertGreaterThanOrEqual(largest.minY, screen.minY - 1)
            XCTAssertLessThanOrEqual(largest.maxX, screen.maxX + 1)
            XCTAssertLessThanOrEqual(largest.maxY, screen.maxY + 1)
            XCTAssertTrue(controller.handleMagnification(delta: -0.01, phase: .changed, locationInWindow: location))
            XCTAssertLessThan(editor.frame.width, largest.width)
            XCTAssertTrue(controller.handleMagnification(delta: -100, phase: .changed, locationInWindow: location))
            let smallest = editor.frame.size
            XCTAssertGreaterThanOrEqual(smallest.width, 320 - 0.01)
            XCTAssertGreaterThanOrEqual(smallest.height, 280 - 0.01)
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .changed, locationInWindow: location))
            XCTAssertGreaterThan(editor.frame.width, smallest.width)
            XCTAssertGreaterThan(editor.frame.height, smallest.height)
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .ended, locationInWindow: location))
            XCTAssertEqual(editor.frame.width, smallest.width * 1.01 * 1.01, accuracy: 0.001)
            XCTAssertEqual(text.string, source)
            XCTAssertEqual(diagnostics.events.filter { $0.reason == .sizeLimit }.count, 2)
            XCTAssertEqual(diagnostics.events.last?.reason, .continuousResizeFinished)
        }
    }

    func testZeroMotionFloatingPinchResumesDetachmentMorph() throws {
        try withPanel { controller, panel, editor, _ in
            let start = header(panel, editor)
            let release = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start)
            editor.dragHandle.onMove?(release)
            editor.dragHandle.onEnd?(release)
            pinch(controller, editor: editor, delta: 0)
            settle()
            XCTAssertEqual(editor.frame.size, PanelSize.standard.floatingDimensions)
        }
    }
}
