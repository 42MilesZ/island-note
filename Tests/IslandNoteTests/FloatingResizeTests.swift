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
    private func settle(_ interval: TimeInterval = 0.8) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
    private func withPanel(diagnostics: InteractionDiagnostics? = nil, openingDelay: TimeInterval = 1.1,
                           content: String? = nil,
                           _ body: (IslandNoteController, IslandPanel, NoteEditorView, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-resize-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("fixture.md")
        let fixtureSource = content ?? source
        try fixtureSource.write(to: note, atomically: true, encoding: .utf8)
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
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), fixtureSource)
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
            XCTAssertEqual(editor.frame.width, 506, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, 302.5, accuracy: 0.001)
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
            XCTAssertEqual(editor.frame.size, PanelSize.standard.floatingDimensions)
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
            // Arrival precedes the queued Ease In Out viewport transition.
            settle(1.1)
            XCTAssertEqual(panel.level, .screenSaver)
            XCTAssertEqual(editor.frame.width, 506, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, 302.5, accuracy: 0.001)
            XCTAssertTrue(diagnostics.events.contains { $0.reason == .resizeCompleted && abs($0.state.width - 506) < 0.001 })
            // A second gesture continues resizing instead of stopping at a preset.
            pinch(controller, editor: editor, delta: 0.1)
            settle()
            XCTAssertEqual(editor.frame.width, 556.6, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, 332.75, accuracy: 0.001)
            XCTAssertFalse(diagnostics.events.contains { $0.reason == .presetLimit })
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
            XCTAssertEqual(editor.frame.width, 506, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, 302.5, accuracy: 0.001)
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
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    XCTAssertNotEqual(editor.frame.width, size.width, accuracy: 0.01)
                }
                settle(0.06)
                let visible = screenRect(panel, editor)
                XCTAssertEqual(visible.midX, initial.midX, accuracy: 1)
                XCTAssertEqual(visible.midY, initial.midY, accuracy: 1)
            }
            // Continue within the same gesture past the old large preset, then reverse.
            XCTAssertTrue(controller.handleMagnification(delta: 100, phase: .changed, locationInWindow: location))
            settle(1.1)
            let screen = try XCTUnwrap(panel.screen).visibleFrame
            let largest = screenRect(panel, editor)
            XCTAssertLessThanOrEqual(largest.width, min(1200, screen.width) + 1)
            XCTAssertLessThanOrEqual(largest.height, min(1000, screen.height) + 1)
            let overlap = largest.intersection(screen)
            XCTAssertGreaterThanOrEqual(overlap.width, 40)
            XCTAssertGreaterThanOrEqual(overlap.height, 40)
            XCTAssertEqual(largest.midX, initial.midX, accuracy: 1)
            XCTAssertEqual(largest.midY, initial.midY, accuracy: 1)
            XCTAssertTrue(controller.handleMagnification(delta: -0.01, phase: .changed, locationInWindow: location))
            settle(0.08)
            XCTAssertLessThan(editor.frame.width, largest.width)
            XCTAssertTrue(controller.handleMagnification(delta: -100, phase: .changed, locationInWindow: location))
            settle(1.1)
            let smallest = editor.frame.size
            XCTAssertGreaterThanOrEqual(smallest.width, 320 - 0.01)
            XCTAssertGreaterThanOrEqual(smallest.height, 280 - 0.01)
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .changed, locationInWindow: location))
            settle(0.1)
            XCTAssertGreaterThan(editor.frame.width, smallest.width)
            XCTAssertGreaterThan(editor.frame.height, smallest.height)
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .ended, locationInWindow: location))
            settle()
            XCTAssertEqual(editor.frame.width, smallest.width * 1.01 * 1.01, accuracy: 0.001)
            XCTAssertEqual(text.string, source)
            XCTAssertEqual(diagnostics.events.filter { $0.reason == .sizeLimit }.count, 2)
            XCTAssertTrue(diagnostics.events.contains { $0.reason == .continuousResizeFinished })
            XCTAssertEqual(diagnostics.events.last?.reason, .resizeCompleted)
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

    func testZeroMotionPinchResumesFollowAndEdgeGrabCancelsItsTail() throws {
        try withPanel { controller, panel, editor, _ in
            let start = header(panel, editor)
            let release = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start)
            editor.dragHandle.onMove?(release)
            editor.dragHandle.onEnd?(release)
            settle()
            let initial = editor.frame.size
            pinch(controller, editor: editor, delta: 0.15)
            settle(0.08)
            let intermediate = editor.frame.size
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertGreaterThan(intermediate.width, initial.width)
                XCTAssertLessThan(intermediate.width, initial.width * 1.15)
            }
            pinch(controller, editor: editor, delta: 0)
            XCTAssertEqual(editor.frame.width, intermediate.width, accuracy: 0.1)
            settle(1.1)
            XCTAssertEqual(editor.frame.width, initial.width * 1.15, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, initial.height * 1.15, accuracy: 0.001)
            pinch(controller, editor: editor, delta: 0.1)
            settle(0.07)
            let beforeEdge = screenRect(panel, editor)
            let mouse = NSPoint(x: beforeEdge.maxX, y: beforeEdge.midY)
            controller.beginEdgeResize(edges: .right, at: mouse)
            controller.endEdgeResize(at: NSPoint(x: mouse.x + 40, y: mouse.y))
            let customized = editor.frame.size
            XCTAssertEqual(customized.width, beforeEdge.width + 40, accuracy: 0.01)
            settle(1.1)
            XCTAssertEqual(editor.frame.size, customized)
        }
    }

    func testDockedPinchTracksSmallDeltasWithFixedTopAndPreservesCustomSize() throws {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        try withPanel(diagnostics: diagnostics) { controller, panel, editor, text in
            let initial = screenRect(panel, editor), home = panel.frame.origin
            text.setSelectedRange(NSRange(location: 24, length: 9))
            let selection = text.selectedRange()
            let font = try XCTUnwrap(text.textStorage?.attribute(.font, at: 24, effectiveRange: nil) as? NSFont)
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .began, locationInWindow: location))
            var size = initial.size
            for delta: CGFloat in [0.01, 0.015, 0.02, -0.025, 0.01] {
                XCTAssertTrue(controller.handleMagnification(delta: delta, phase: .changed, locationInWindow: location))
                size.width *= 1 + delta; size.height *= 1 + delta
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    XCTAssertNotEqual(editor.frame.width, size.width, accuracy: 0.01)
                }
                settle(0.06)
                let visible = screenRect(panel, editor)
                XCTAssertEqual(visible.maxY, initial.maxY, accuracy: 0.001)
                XCTAssertEqual(visible.midX, initial.midX, accuracy: 0.001)
                XCTAssertEqual(panel.frame.origin, home)
            }
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .ended, locationInWindow: location))
            size.width *= 1.01; size.height *= 1.01
            settle()
            XCTAssertEqual(editor.frame.width, size.width, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, size.height, accuracy: 0.001)
            XCTAssertEqual(text.selectedRange(), selection)
            XCTAssertEqual((text.textStorage?.attribute(.font, at: 24, effectiveRange: nil) as? NSFont)?.pointSize, font.pointSize)
            XCTAssertEqual(text.string, source)
            XCTAssertEqual(diagnostics.events.last?.reason, .resizeCompleted)

            controller.collapse(); settle(1.1)
            controller.expand(); settle(1.1)
            XCTAssertEqual(editor.frame.width, size.width, accuracy: 0.001)
            let start = header(panel, editor)
            let out = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start); editor.dragHandle.onMove?(out); editor.dragHandle.onEnd?(out)
            settle()
            let back = header(panel, editor)
            editor.dragHandle.onBegin?(back); editor.dragHandle.onMove?(start); editor.dragHandle.onEnd?(start)
            settle()
            XCTAssertEqual(editor.frame.width, size.width, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, size.height, accuracy: 0.001)
            XCTAssertEqual(panel.frame.origin, home)
        }
    }

    func testDockedLimitsReverseImmediatelyAndZeroMotionResumesFollow() throws {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        try withPanel(diagnostics: diagnostics) { controller, panel, editor, _ in
            let initial = screenRect(panel, editor), home = panel.frame.origin
            pinch(controller, editor: editor, delta: 0.15)
            settle(0.08)
            let intermediate = editor.frame.width
            pinch(controller, editor: editor, delta: 0)
            XCTAssertEqual(editor.frame.width, intermediate, accuracy: 0.1)
            settle(1.1)
            XCTAssertEqual(editor.frame.width, initial.width * 1.15, accuracy: 0.001)
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            XCTAssertTrue(controller.handleMagnification(delta: 100, phase: .began, locationInWindow: location))
            settle(1.1)
            let largest = screenRect(panel, editor), screen = try XCTUnwrap(panel.screen)
            XCTAssertEqual(largest.maxY, initial.maxY, accuracy: 0.001)
            XCTAssertEqual(largest.midX, initial.midX, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(largest.minY, screen.visibleFrame.minY - 0.001)
            XCTAssertLessThanOrEqual(largest.width, min(1200, screen.visibleFrame.width) + 0.001)
            XCTAssertTrue(controller.handleMagnification(delta: -0.01, phase: .changed, locationInWindow: location))
            settle(0.08)
            XCTAssertLessThan(editor.frame.width, largest.width)
            XCTAssertTrue(controller.handleMagnification(delta: -100, phase: .changed, locationInWindow: location))
            settle(1.1)
            let smallest = editor.frame.size
            XCTAssertGreaterThanOrEqual(smallest.width, 320 - 0.001)
            XCTAssertGreaterThanOrEqual(smallest.height, 190 - 0.001)
            XCTAssertLessThan(smallest.width, initial.width)
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .changed, locationInWindow: location))
            settle(0.1)
            XCTAssertGreaterThan(editor.frame.width, smallest.width)
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .cancelled, locationInWindow: location))
            settle()
            XCTAssertEqual(editor.frame.width, smallest.width * 1.01, accuracy: 0.001)
            XCTAssertEqual(panel.frame.origin, home)
            XCTAssertEqual(diagnostics.events.filter { $0.reason == .sizeLimit }.count, 2)
        }
    }

    func testDockingGestureAccumulatesAndContinuesAfterArrival() throws {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        try withPanel(diagnostics: diagnostics) { controller, panel, editor, _ in
            let home = panel.frame.origin, start = header(panel, editor)
            let out = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start); editor.dragHandle.onMove?(out); editor.dragHandle.onEnd?(out)
            settle()
            let back = header(panel, editor)
            editor.dragHandle.onBegin?(back); editor.dragHandle.onMove?(start); editor.dragHandle.onEnd?(start)
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .began, locationInWindow: location))
            XCTAssertTrue(controller.handleMagnification(delta: 0.02, phase: .changed, locationInWindow: location))
            let factor: CGFloat = 1.01 * 1.02
            let queued = try XCTUnwrap(diagnostics.events.last { $0.reason == .resizeQueued })
            XCTAssertEqual(try XCTUnwrap(queued.state.targetWidth), 460 * factor, accuracy: 0.001)
            settle(0.45)
            XCTAssertEqual(panel.frame.origin, home)
            XCTAssertTrue(controller.handleMagnification(delta: -0.01, phase: .changed, locationInWindow: location))
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
            settle(1.1)
            XCTAssertEqual(editor.frame.width, 460 * factor * 0.99, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, 275 * factor * 0.99, accuracy: 0.001)
            XCTAssertEqual(diagnostics.events.last?.reason, .resizeCompleted)
        }
    }

    func testCornerHoverChangesAreRecordedWithoutPointerCoordinates() throws {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        try withPanel(diagnostics: diagnostics) { _, panel, editor, _ in
            let start = header(panel, editor)
            let release = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start)
            editor.dragHandle.onMove?(release)
            editor.dragHandle.onEnd?(release)
            settle()
            let r = editor.frame
            for point in [NSPoint(x: r.minX + 32, y: r.minY + 32), NSPoint(x: r.midX, y: r.midY)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                panel.sendEvent(event)
                XCTAssertEqual(diagnostics.events.last?.reason, .resizeHoverChanged)
            }
            let entries = diagnostics.events.filter { $0.reason == .resizeHoverChanged }
            XCTAssertEqual(entries.first?.state.resizeHoverEdges, PanelResizeEdges([.left, .bottom]).rawValue)
            XCTAssertNil(entries.last?.state.resizeHoverEdges)
        }
    }

    func testLostEdgeReleaseRecoversPinchButActiveEdgeDragKeepsOwnership() throws {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        try withPanel(diagnostics: diagnostics) { controller, panel, editor, _ in
            let start = header(panel, editor)
            let out = NSPoint(x: start.x + 80, y: start.y - 170)
            editor.dragHandle.onBegin?(start); editor.dragHandle.onMove?(out); editor.dragHandle.onEnd?(out)
            settle()
            let rect = screenRect(panel, editor)
            controller.beginEdgeResize(edges: .right, at: NSPoint(x: rect.maxX, y: rect.midY))
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            XCTAssertFalse(controller.handleMagnification(delta: 0.01, phase: .began,
                locationInWindow: location, pressedMouseButtons: 1))
            XCTAssertEqual(diagnostics.events.last?.reason, .edgeResizing)
            // No mouse-up reaches the handle. The physical button has been released.
            XCTAssertTrue(controller.handleMagnification(delta: 0.01, phase: .began,
                locationInWindow: location, pressedMouseButtons: 0))
            settle()
            XCTAssertEqual(editor.frame.width, rect.width * 1.01, accuracy: 0.001)
            XCTAssertTrue(diagnostics.events.contains { $0.reason == .edgeResizeInterrupted })
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
        }
    }

    func testSettingsProtectDockedAndFloatingPanelFromAutomaticCollapse() throws {
        try withPanel { controller, panel, editor, _ in
            let initial = editor.frame
            controller.collapse(automatically: true)
            // Settings opens before an already queued collapse can flush the editor.
            controller.showSettings()
            settle(0.2)
            let settings = try XCTUnwrap(NSApp.windows.first { $0.windowController is SettingsWindowController })
            defer { settings.close() }
            XCTAssertFalse(editor.isHidden)
            XCTAssertEqual(editor.frame, initial)
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40),
                modifierFlags: [], timestamp: 0, windowNumber: settings.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(click)
            controller.collapse(automatically: true)
            settle(0.2)
            XCTAssertFalse(editor.isHidden)
            settings.close()
            controller.collapse(automatically: true); settle(1.1)
            XCTAssertTrue(editor.isHidden)
            controller.expand(); settle(1.1)
            let start = header(panel, editor), out = NSPoint(x: header(panel, editor).x + 80, y: header(panel, editor).y - 170)
            editor.dragHandle.onBegin?(start); editor.dragHandle.onMove?(out); editor.dragHandle.onEnd?(out)
            settle()
            let floating = screenRect(panel, editor)
            controller.showSettings(); settle(0.5)
            XCTAssertFalse(editor.isHidden)
            XCTAssertEqual(screenRect(panel, editor), floating)
            XCTAssertEqual(panel.level, .floating)
            settings.close()
        }
    }

    func testRapidPinchOnLongNoteRetargetsWithoutSynchronousLayoutAndSettles() throws {
        let content = String(repeating: "## Heading\n\nA long paragraph with **formatting** and enough text to wrap on resize.\n\n", count: 600)
        try withPanel(content: content) { controller, _, editor, text in
            text.setSelectedRange(NSRange(location: 120, length: 12))
            let selection = text.selectedRange()
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            var size = editor.frame.size
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .began, locationInWindow: location))
            // A burst must accumulate every logical delta without laying out each input.
            let beforeBurst = editor.frame
            let deltas = Array(repeating: CGFloat(0.009), count: 48) + Array(repeating: CGFloat(-0.006), count: 24)
            for delta in deltas {
                XCTAssertTrue(controller.handleMagnification(delta: delta, phase: .changed, locationInWindow: location))
                size.width *= 1 + delta; size.height *= 1 + delta
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    XCTAssertEqual(editor.frame, beforeBurst)
                }
            }
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
            settle(1.1)
            XCTAssertEqual(editor.frame.width, size.width, accuracy: 0.001)
            XCTAssertEqual(editor.frame.height, size.height, accuracy: 0.001)
            XCTAssertEqual(text.selectedRange(), selection)
            XCTAssertTrue(text.isVerticallyResizable)
            XCTAssertTrue(try XCTUnwrap(text.enclosingScrollView).contentView.postsFrameChangedNotifications)
        }
    }

    func testResizeRestoresEditorNotificationsOnReleaseCancellationAndFocusLoss() throws {
        let content = "# Note\n\n" + String(repeating: "A paragraph of text that wraps in the editor.\n\n", count: 150)
            + "\n| Column A | Column B |\n| --- | --- |\n| A longer cell that wraps | Another cell |\n\n```swift\nlet value = 1\n```\n"
        try withPanel(content: content) { controller, panel, editor, text in
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            let originalFlag = scroll.contentView.postsFrameChangedNotifications
            let originalBoundsFlag = scroll.contentView.postsBoundsChangedNotifications
            let originalVerticalResize = text.isVerticallyResizable
            XCTAssertTrue(originalFlag)
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            let oldWidth = try XCTUnwrap(text.textContainer).size.width
            XCTAssertTrue(controller.handleMagnification(delta: -0.1, phase: .began, locationInWindow: location))
            XCTAssertFalse(scroll.contentView.postsFrameChangedNotifications)
            XCTAssertFalse(scroll.contentView.postsBoundsChangedNotifications)
            XCTAssertFalse(text.isVerticallyResizable)
            settle(0.1)
            XCTAssertLessThan(try XCTUnwrap(text.textContainer).size.width, oldWidth)
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
            settle(1.1)
            XCTAssertEqual(scroll.contentView.postsFrameChangedNotifications, originalFlag)
            XCTAssertEqual(scroll.contentView.postsBoundsChangedNotifications, originalBoundsFlag)
            XCTAssertEqual(text.isVerticallyResizable, originalVerticalResize)
            XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
            XCTAssertTrue(controller.handleMagnification(delta: 0.02, phase: .began, locationInWindow: location))
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .cancelled, locationInWindow: location))
            settle(1.1)
            XCTAssertEqual(scroll.contentView.postsFrameChangedNotifications, originalFlag)
            XCTAssertTrue(controller.handleMagnification(delta: 0.02, phase: .began, locationInWindow: location))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
            settle(1.1)
            XCTAssertEqual(scroll.contentView.postsFrameChangedNotifications, originalFlag)
            XCTAssertEqual(scroll.contentView.postsBoundsChangedNotifications, originalBoundsFlag)
            XCTAssertEqual(text.isVerticallyResizable, originalVerticalResize)
            // Ordinary scrolling and another resize still work after the interrupted session.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
            pinch(controller, editor: editor, delta: 0.01)
            settle(1.1)
            XCTAssertEqual(scroll.contentView.postsFrameChangedNotifications, originalFlag)
        }
    }

    func testPinchAtDocumentEndRetainsReadableScrollPosition() throws {
        let content = String(repeating: "A long paragraph with enough text to wrap when the viewport changes width.\n\n", count: 400)
        try withPanel(content: content) { controller, _, editor, text in
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height - 2)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(0.3)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000)
            let location = NSPoint(x: editor.frame.midX, y: editor.frame.midY)
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .began, locationInWindow: location))
            var durations: [Double] = []
            for i in 0..<40 {
                let began = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(controller.handleMagnification(delta: i % 2 == 0 ? 0.01 : -0.0099009900990099,
                    phase: .changed, locationInWindow: location))
                durations.append(ProcessInfo.processInfo.systemUptime - began)
                settle(0.008)
            }
            XCTAssertTrue(controller.handleMagnification(delta: 0, phase: .ended, locationInWindow: location))
            settle(1.1)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000)
            XCTAssertLessThanOrEqual(scroll.contentView.bounds.maxY, try XCTUnwrap(scroll.documentView).bounds.height + 1)
            XCTAssertTrue(scroll.contentView.postsFrameChangedNotifications)
            XCTAssertTrue(text.isVerticallyResizable)
            print("Document-end resize fixture: mean \(durations.reduce(0, +) / Double(durations.count) * 1000) ms, max \(durations.max()! * 1000) ms")
        }
    }
}
