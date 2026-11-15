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

    private func metrics(width: CGFloat, height: CGFloat) -> NotchMetrics {
        let side = (1512 - width) / 2
        return NotchMetrics(screenWidth: 1512, safeAreaTop: height,
                            topLeftArea: NSRect(x: 0, y: 0, width: side, height: height),
                            topRightArea: NSRect(x: side + width, y: 0, width: side, height: height))
    }
}
