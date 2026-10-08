import AppKit

/// Header-only dragging leaves native text selection and the status button intact.
final class PanelDragView: NSView {
    var onBegin: ((NSPoint) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: ((NSPoint) -> Void)?
    private var hoverArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.clear.cgColor
        refreshLocalizedUI()
    }

    func refreshLocalizedUI() {
        setAccessibilityLabel(L10n.tr("Drag panel"))
        setAccessibilityHelp(L10n.tr("Drag away to float. Move back to the island and release to dock. Escape docks and collapses."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        onBegin?(screenPoint(for: event))
    }
    override func mouseDragged(with event: NSEvent) { onMove?(screenPoint(for: event)) }
    override func mouseUp(with event: NSEvent) {
        onEnd?(screenPoint(for: event))
        let hovered = bounds.contains(convert(event.locationInWindow, from: nil))
        setHovered(hovered)
        (hovered ? NSCursor.openHand : NSCursor.arrow).set()
    }

    func clearHover() { setHovered(false) }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func setHovered(_ hovered: Bool) {
        let color = NSColor.white.withAlphaComponent(hovered ? 0.10 : 0).cgColor
        let previous = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = color
        CATransaction.commit()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = previous
            fade.toValue = color
            fade.duration = 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "hover")
        }
    }
}

/// Screen-space rules shared by dragging, docking, and display recovery.
enum PanelDocking {
    static let dragThreshold: CGFloat = 4
    static let separationDistance: CGFloat = 54
    static let headerInset: CGFloat = 19

    static func headerContact(rect: NSRect, island: NSRect) -> NSPoint {
        // Any point along the actual drag strip can meet the island. A grip near
        // either edge must not require the user to align the panel's center.
        NSPoint(x: min(max(island.midX, rect.minX + 28), rect.maxX - 47),
                y: rect.maxY - headerInset)
    }

    static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func isNearIsland(header: NSPoint, island: NSRect, wasNear: Bool = false) -> Bool {
        island.insetBy(dx: wasNear ? -56 : -32, dy: wasNear ? -64 : -40).contains(header)
    }

    static func attraction(header: NSPoint, island: NSRect) -> CGFloat {
        // A wider, continuous influence field starts before the capture threshold.
        // Threshold crossings only gate haptics/docking, never the contour itself.
        let x = abs(header.x - island.midX) / (island.width / 2 + 80)
        let y = abs(header.y - island.midY) / (island.height / 2 + 88)
        let t = max(0, 1 - hypot(x, y))
        return t * t * (3 - 2 * t)
    }

    /// Keep the complete header reachable even when the panel exceeds a small display.
    static func constrainedOrigin(_ origin: NSPoint, rect: NSRect, screen: NSRect) -> NSPoint {
        let xMin = screen.minX - rect.minX
        let xMax = max(xMin, screen.maxX - rect.maxX)
        let yMax = screen.maxY - rect.maxY
        let yMin = min(yMax, screen.minY - rect.minY)
        return NSPoint(x: min(max(origin.x, xMin), xMax), y: min(max(origin.y, yMin), yMax))
    }
}

/// Same path topology in both modes lets the contour morph without replacing the editor.
enum PanelContour {
    static func bridgePath(island r: NSRect, body: NSRect, connection: CGFloat) -> CGPath? {
        let gap = r.minY - body.maxY
        let reach = min(1, max(0, (130 - gap) / 65))
        let contact = min(1, max(0, (gap + 24) / 24))
        let amount = connection * reach * contact
        guard amount > 0.0001 else { return nil }
        let meetX = min(r.maxX - 28, max(r.minX + 28, body.midX))
        let bodyX = min(body.maxX - 50, max(body.minX + 50, meetX))
        let upperY = r.minY + 8, lowerY = body.maxY - 1
        let upperW = 34 * amount, lowerW = 38 * amount
        let bendY = (upperY + lowerY) / 2
        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: meetX - upperW, y: upperY))
        neck.addCurve(to: CGPoint(x: bodyX - lowerW, y: lowerY),
                      control1: CGPoint(x: meetX - upperW * 0.25, y: bendY),
                      control2: CGPoint(x: bodyX - lowerW * 0.25, y: bendY))
        neck.addLine(to: CGPoint(x: bodyX + lowerW, y: lowerY))
        neck.addCurve(to: CGPoint(x: meetX + upperW, y: upperY),
                      control1: CGPoint(x: bodyX + lowerW * 0.25, y: bendY),
                      control2: CGPoint(x: meetX + upperW * 0.25, y: bendY))
        neck.closeSubpath()
        return neck
    }

    static func path(_ r: CGRect, floating: CGFloat, pull: CGFloat = 0, towardX: CGFloat? = nil,
                     topRadius: CGFloat = 10, bottomRadius: CGFloat = 32) -> CGPath {
        let f = min(1, max(0, floating))
        let sideInset = topRadius * (1 - f)
        let radius = topRadius + (24 - topRadius) * f
        let left = r.minX + sideInset, right = r.maxX - sideInset
        let topLeft = r.minX + 24 * f, topRight = r.maxX - 24 * f
        let middle = min(right - 70, max(left + 70, towardX ?? r.midX))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: topLeft, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: left, y: r.maxY - radius),
                       control: CGPoint(x: r.minX + topRadius * (1 - f), y: r.maxY))
        p.addLine(to: CGPoint(x: left, y: r.minY + bottomRadius))
        p.addQuadCurve(to: CGPoint(x: left + bottomRadius, y: r.minY), control: CGPoint(x: left, y: r.minY))
        p.addLine(to: CGPoint(x: right - bottomRadius, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: right, y: r.minY + bottomRadius), control: CGPoint(x: right, y: r.minY))
        p.addLine(to: CGPoint(x: right, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: topRight, y: r.maxY),
                       control: CGPoint(x: r.maxX - topRadius * (1 - f), y: r.maxY))
        p.addCurve(to: CGPoint(x: middle, y: r.maxY + pull),
                   control1: CGPoint(x: topRight - 45, y: r.maxY),
                   control2: CGPoint(x: middle + 35, y: r.maxY + pull))
        p.addCurve(to: CGPoint(x: topLeft, y: r.maxY),
                   control1: CGPoint(x: middle - 35, y: r.maxY + pull),
                   control2: CGPoint(x: topLeft + 45, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
