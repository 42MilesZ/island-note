import XCTest
import AppKit
@testable import IslandNote

final class PanelDragTests: XCTestCase {
    @MainActor
    func testShadowCanvasStaysAnchoredAcrossNativeWindowLifecycle() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let gutter: CGFloat = 64
        let canvas = NSRect(x: screen.frame.midX - 409, y: screen.frame.maxY - 614, width: 818, height: 678)
        let panel = IslandPanel(contentRect: canvas, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.orderFrontRegardless()
        panel.makeKey()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(panel.frame.origin, canvas.origin)
        XCTAssertEqual(panel.frame.maxY - gutter, screen.frame.maxY)
        panel.level = .floating
        panel.setFrameOrigin(canvas.origin)
        panel.level = .screenSaver
        panel.makeKey()
        XCTAssertEqual(panel.frame.origin, canvas.origin)
        XCTAssertEqual(panel.constrainFrameRect(canvas, to: screen), canvas)
        panel.close()
    }

    func testOffCenterGripsCanDockForBothPanelSizes() {
        let island = NSRect(x: 700, y: 967, width: 200, height: 33)
        for size in [PanelSize.standard, .large] {
            for gripX in [CGFloat(30), size.dimensions.width - 50] {
                let rect = NSRect(x: island.midX - gripX, y: 1000 - size.dimensions.height,
                                  width: size.dimensions.width, height: size.dimensions.height)
                let contact = PanelDocking.headerContact(rect: rect, island: island)
                XCTAssertTrue(PanelDocking.isNearIsland(header: contact, island: island), "\(size) grip \(gripX)")
            }
        }
        let bodyOnly = NSRect(x: 600, y: 350, width: 460, height: 550)
        XCTAssertFalse(PanelDocking.isNearIsland(header: PanelDocking.headerContact(rect: bodyOnly, island: island), island: island))
    }

    @MainActor
    func testHeaderOwnsDraggingWithoutCoveringStatusOrText() {
        _ = NSApplication.shared
        let editor = NoteEditorView(frame: NSRect(origin: .zero, size: PanelSize.standard.dimensions))
        editor.layoutSubtreeIfNeeded()
        let header = editor.dragHandle.frame
        XCTAssertEqual(header.height, 30)
        XCTAssertEqual(header.maxY, editor.bounds.maxY - 4)
        XCTAssertTrue(editor.hitTest(NSPoint(x: header.midX, y: header.midY)) === editor.dragHandle)
        XCTAssertFalse(editor.hitTest(NSPoint(x: editor.bounds.maxX - 27, y: header.midY)) === editor.dragHandle)
        XCTAssertFalse(editor.hitTest(NSPoint(x: header.midX, y: header.minY - 20)) === editor.dragHandle)
    }

    func testDockEntryAndExitHaveHysteresis() {
        let island = NSRect(x: -100, y: 967, width: 200, height: 33)
        let edge = NSPoint(x: 145, y: 980)
        XCTAssertFalse(PanelDocking.isNearIsland(header: edge, island: island))
        XCTAssertTrue(PanelDocking.isNearIsland(header: edge, island: island, wasNear: true))
        XCTAssertFalse(PanelDocking.isNearIsland(header: NSPoint(x: 200, y: 980), island: island, wasNear: true))
        XCTAssertGreaterThan(PanelDocking.attraction(header: NSPoint(x: 0, y: 980), island: island),
                             PanelDocking.attraction(header: edge, island: island))
    }

    func testShapeInfluenceIsContinuousAcrossBothHapticThresholds() {
        let island = NSRect(x: -100, y: 967, width: 200, height: 33)
        for boundary in [island.minY - 40, island.minY - 64] {
            let outside = NSPoint(x: island.midX, y: boundary - 0.01)
            let inside = NSPoint(x: island.midX, y: boundary + 0.01)
            XCTAssertGreaterThan(PanelDocking.attraction(header: outside, island: island), 0)
            XCTAssertEqual(PanelDocking.attraction(header: outside, island: island),
                           PanelDocking.attraction(header: inside, island: island), accuracy: 0.001)
        }
        let toward = stride(from: CGFloat(870), through: CGFloat(980), by: 1).map {
            PanelDocking.attraction(header: NSPoint(x: island.midX, y: $0), island: island)
        }
        for pair in zip(toward, toward.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1, pair.0)
            XCTAssertLessThan(pair.1 - pair.0, 0.02)
        }
    }

    func testLargeOffCenterBubbleConnectionDoesNotCutAtCenterDistance() throws {
        let island = NSRect(x: -100, y: 967, width: 200, height: 33)
        var previous: NSRect?
        for offset in stride(from: CGFloat(210), through: CGFloat(320), by: 1) {
            let body = NSRect(x: offset - 345, y: 377, width: 690, height: 550)
            let contact = PanelDocking.headerContact(rect: body, island: island)
            let amount = PanelDocking.attraction(header: contact, island: island)
            let path = try XCTUnwrap(PanelContour.bridgePath(island: island, body: body, connection: amount))
            let bounds = path.boundingBoxOfPath
            if let previous { XCTAssertLessThan(abs(bounds.width - previous.width), 2) }
            previous = bounds
        }
    }

    func testFloatingPanelRetainsFortyPointOverlapAtEveryEdgeAndCorner() {
        let rect = NSRect(x: 64, y: 64, width: 690, height: 550)
        for screen in [NSRect(x: -1280, y: -800, width: 1280, height: 776),
                       NSRect(x: 900, y: 200, width: 500, height: 400)] {
            for x in [screen.minX - 2000, screen.midX - rect.midX, screen.maxX + 2000] {
                for y in [screen.minY - 2000, screen.midY - rect.midY, screen.maxY + 2000] {
                    let requested = NSPoint(x: x, y: y)
                    let origin = PanelDocking.constrainedOrigin(requested, rect: rect, screen: screen)
                    let overlap = rect.offsetBy(dx: origin.x, dy: origin.y).intersection(screen)
                    XCTAssertGreaterThanOrEqual(overlap.width, 40)
                    XCTAssertGreaterThanOrEqual(overlap.height, 40)
                    if x != screen.midX - rect.midX { XCTAssertEqual(overlap.width, 40) }
                    if y != screen.midY - rect.midY { XCTAssertEqual(overlap.height, 40) }
                    XCTAssertEqual(PanelDocking.constrainedOrigin(origin, rect: rect, screen: screen), origin)
                }
            }
            // A partly hidden panel inside the overlap limit must not jump on release.
            let partial = NSPoint(x: screen.minX - rect.maxX + 80, y: screen.minY - rect.maxY + 60)
            XCTAssertEqual(PanelDocking.constrainedOrigin(partial, rect: rect, screen: screen), partial)
        }
        let tiny = NSRect(x: 10, y: 20, width: 30, height: 25)
        let origin = PanelDocking.constrainedOrigin(.zero, rect: rect, screen: tiny)
        XCTAssertEqual(rect.offsetBy(dx: origin.x, dy: origin.y).intersection(tiny), tiny)
    }

    func testContourMorphKeepsTopologyAndTextFootprint() {
        let rect = NSRect(x: 64, y: 64, width: 460, height: 275)
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var result: [CGPathElementType] = []
            path.applyWithBlock { result.append($0.pointee.type) }
            return result
        }
        let attached = PanelContour.path(rect, floating: 0)
        let detached = PanelContour.path(rect, floating: 1)
        let pulled = PanelContour.path(rect, floating: 1, pull: 10, towardX: rect.minX)
        XCTAssertEqual(elements(attached), elements(detached))
        XCTAssertEqual(elements(detached), elements(pulled))
        XCTAssertEqual(detached.boundingBoxOfPath, rect)
        XCTAssertEqual(pulled.boundingBoxOfPath.width, rect.width)
        XCTAssertEqual(pulled.boundingBoxOfPath.maxY, rect.maxY + 10)
    }

    @MainActor
    func testDragCancellationFloatingReleaseDockAndInterruption() {
        _ = NSApplication.shared
        let rect = NSRect(x: 64, y: 64, width: 460, height: 275)
        let home = NSPoint(x: 200, y: 300)
        let panel = IslandPanel(contentRect: NSRect(origin: home, size: NSSize(width: 588, height: 403)),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let mask = CAShapeLayer()
        let shadow = CALayer()
        var docks: [Bool] = []
        let interaction = PanelDragCoordinator(panel: panel, mask: mask, shadow: shadow,
            anchorRect: NSRect(x: 394, y: 606, width: 200, height: 33), dockOrigin: home,
            getRect: { rect }, onDock: { docks.append($0) })
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.55)) }
        let start = NSPoint(x: 440, y: 620)
        interaction.begin(at: start)
        interaction.move(to: NSPoint(x: start.x + 2, y: start.y))
        XCTAssertEqual(panel.frame.origin, home)
        interaction.end(at: start)
        XCTAssertFalse(interaction.preventsCollapse)

        interaction.begin(at: start)
        interaction.move(to: NSPoint(x: start.x, y: start.y - 20))
        XCTAssertFalse(interaction.isFloating)
        interaction.end(at: NSPoint(x: start.x, y: start.y - 20))
        interaction.begin(at: start)
        interaction.end(at: start) // Clicking during the short return must still finish docking.
        settle()
        XCTAssertEqual(panel.frame.origin, home)
        XCTAssertEqual(docks, [false])

        interaction.begin(at: start)
        let far = NSPoint(x: start.x + 250, y: start.y - 220)
        interaction.move(to: far)
        XCTAssertTrue(interaction.isFloating)
        interaction.end(at: far)
        settle()
        XCTAssertTrue(interaction.preventsCollapse)
        XCTAssertFalse(interaction.isInteracting)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertGreaterThan(shadow.shadowOpacity, 0)
        XCTAssertEqual(shadow.shadowRadius, 14, accuracy: 0.01)
        XCTAssertEqual(shadow.shadowOffset.height, -6, accuracy: 0.01)

        interaction.cancelAndDock(collapse: true)
        interaction.begin(at: far)
        interaction.move(to: NSPoint(x: far.x + 80, y: far.y - 80))
        interaction.end(at: NSPoint(x: far.x + 80, y: far.y - 80))
        settle()
        XCTAssertTrue(interaction.isFloating)
        XCTAssertEqual(docks, [false]) // Stale docking completion must not collapse a new drag.

        interaction.cancelAndDock(collapse: true)
        settle()
        XCTAssertFalse(interaction.preventsCollapse)
        XCTAssertEqual(panel.frame.origin, home)
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertEqual(shadow.shadowOpacity, 0)
        XCTAssertEqual(docks, [false, true])
        for grip in [CGFloat(30), rect.width - 50] {
            let gripStart = NSPoint(x: home.x + rect.minX + grip, y: home.y + rect.maxY - PanelDocking.headerInset)
            let away = NSPoint(x: gripStart.x + 180, y: gripStart.y - 220)
            interaction.begin(at: gripStart)
            interaction.move(to: away)
            interaction.end(at: away)
            settle()
            let currentGrip = NSPoint(x: panel.frame.minX + rect.minX + grip,
                                      y: panel.frame.minY + rect.maxY - PanelDocking.headerInset)
            let returnPoint = NSPoint(x: 494, y: 620)
            interaction.begin(at: currentGrip)
            interaction.move(to: returnPoint)
            interaction.end(at: returnPoint)
            settle()
            XCTAssertFalse(interaction.isFloating, "Off-center grip \(grip) failed to dock")
            XCTAssertEqual(panel.frame.origin, home)
        }
        let newHome = NSPoint(x: -500, y: -200)
        interaction.updateDock(anchorRect: NSRect(x: -306, y: 106, width: 200, height: 33), origin: newHome)
        XCTAssertEqual(panel.frame.origin, newHome)
        panel.close()
    }
}
