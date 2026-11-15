import AppKit
import XCTest
@testable import IslandNote

final class DockGeometryTests: XCTestCase {
    func testScreenWithoutNotchHasNoMetrics() {
        let external = NotchMetrics(screenWidth: 1920, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil)
        XCTAssertFalse(external.hasNotch)
        // Auxiliary areas without a top inset do not describe a camera housing.
        let stray = NotchMetrics(screenWidth: 1512, safeAreaTop: 0,
                                 topLeftArea: NSRect(x: 0, y: 950, width: 660, height: 32),
                                 topRightArea: NSRect(x: 852, y: 950, width: 660, height: 32))
        XCTAssertFalse(stray.hasNotch)
        let touching = NotchMetrics(screenWidth: 1512, safeAreaTop: 32,
                                    topLeftArea: NSRect(x: 0, y: 950, width: 756, height: 32),
                                    topRightArea: NSRect(x: 756, y: 950, width: 756, height: 32))
        XCTAssertFalse(touching.hasNotch)
    }

    func testNotchSizeComesFromAuxiliaryAreasAndTopInset() {
        let notch = NotchMetrics(screenWidth: 1512, safeAreaTop: 32,
                                 topLeftArea: NSRect(x: 0, y: 950, width: 663, height: 32),
                                 topRightArea: NSRect(x: 848, y: 950, width: 664, height: 32))
        XCTAssertEqual(notch.size, NSSize(width: 185, height: 32))
    }

    func testIslandFollowsNotchSize() {
        let small = DockBarLayout(notch: metrics(width: 185, height: 32), canvasWidth: 1000, canvasTop: 900)
        XCTAssertEqual(small.rest.height, 33)
        XCTAssertEqual(small.rest.maxY, 900)
        XCTAssertEqual(small.rest.midX, 500)

        let tall = DockBarLayout(notch: metrics(width: 230, height: 37.5), canvasWidth: 1000, canvasTop: 900)
        XCTAssertEqual(tall.rest.height, 39)
        XCTAssertGreaterThanOrEqual(tall.rest.width, 230)
        XCTAssertGreaterThan(tall.rest.width, small.rest.width)
        XCTAssertEqual(tall.hover.maxY, 900)
        XCTAssertEqual(tall.hover.width, tall.rest.width + 14)
        XCTAssertEqual(tall.restVisible, tall.rest)
    }

    func testRestingIslandIsInvisibleWithoutNotch() {
        let layout = DockBarLayout(notch: NotchMetrics(screenWidth: 1920, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil),
                                   canvasWidth: 1000, canvasTop: 900)
        XCTAssertEqual(layout.restVisible.height, 0)
        XCTAssertEqual(layout.restVisible.maxY, 900)
        // The docking anchor keeps a usable target while dragging back to the top edge.
        XCTAssertEqual(layout.rest.height, DockBarLayout.minimumHeight)
        let path = PanelContour.path(layout.restVisible, floating: 0, topRadius: 0, bottomRadius: 0)
        XCTAssertEqual(path.boundingBoxOfPath.height, 0, accuracy: 0.001)
    }

    func testPeekAndRevealZonesWithoutNotch() {
        let none = NotchMetrics(screenWidth: 1920, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil)
        let layout = DockBarLayout(notch: none, canvasWidth: 1000, canvasTop: 900, menuBarHeight: 24)
        XCTAssertEqual(layout.hover.height, DockBarLayout.peekHeight)
        XCTAssertEqual(layout.hover.maxY, 900)
        XCTAssertEqual(layout.hover.midX, layout.rest.midX)
        XCTAssertLessThan(layout.hover.width, layout.rest.width)
        // Same proportions as the resting capsule: 10 / 33 at the top, 20 / 33 at the bottom.
        XCTAssertEqual(DockBarLayout.peekTopRadius / DockBarLayout.peekHeight, 10 / 33, accuracy: 0.01)
        XCTAssertEqual(DockBarLayout.peekBottomRadius / DockBarLayout.peekHeight, 20 / 33, accuracy: 0.01)

        XCTAssertEqual(layout.openZone.minY, 876, "Resting opens only within the menu bar")
        XCTAssertEqual(layout.peekZone.minY, 876 - DockBarLayout.peekExtraDepth, "The hint starts a little earlier")
        XCTAssertTrue(layout.peekZone.contains(layout.openZone))
        XCTAssertTrue(layout.peekZone.contains(NSPoint(x: layout.rest.maxX + 30, y: 870)))
        XCTAssertFalse(layout.openZone.contains(NSPoint(x: layout.rest.maxX + 30, y: 870)))
        XCTAssertFalse(layout.peekZone.contains(NSPoint(x: 500, y: 850)), "Window content further down stays inert")
        XCTAssertTrue(layout.isAtTopEdge(NSPoint(x: 500, y: 899)))
        XCTAssertTrue(layout.isAtTopEdge(NSPoint(x: 500, y: 900)))
        XCTAssertFalse(layout.isAtTopEdge(NSPoint(x: 500, y: 890)))

        let autoHidden = DockBarLayout(notch: none, canvasWidth: 1000, canvasTop: 900, menuBarHeight: 0)
        XCTAssertEqual(autoHidden.openZone.minY, 900 - DockBarLayout.minimumRevealDepth)
    }

    func testRetractedShapesSitJustBeyondTheTopEdge() {
        let none = NotchMetrics(screenWidth: 1920, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil)
        let layout = DockBarLayout(notch: none, canvasWidth: 1000, canvasTop: 900, menuBarHeight: 24)
        for shape in [layout.rest, layout.hover] {
            let retracted = layout.retracted(shape)
            XCTAssertGreaterThan(retracted.minY, 900)
            XCTAssertEqual(retracted.size, shape.size, "Sliding keeps the rounded shape intact")
            XCTAssertEqual(retracted.minX, shape.minX)
        }
    }

    private func metrics(width: CGFloat, height: CGFloat) -> NotchMetrics {
        let side = (1512 - width) / 2
        return NotchMetrics(screenWidth: 1512, safeAreaTop: height,
                            topLeftArea: NSRect(x: 0, y: 0, width: side, height: height),
                            topRightArea: NSRect(x: side + width, y: 0, width: side, height: height))
    }
}
