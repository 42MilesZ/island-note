import AppKit

final class StatusIndicatorButton: NSButton {
    static let hoverPadding: CGFloat = 6
    var onHover: ((Bool) -> Void)?
    var hoverBounds: NSRect { bounds.insetBy(dx: -Self.hoverPadding, dy: -Self.hoverPadding) }
    private var hoverArea: NSTrackingArea?
    private weak var hoverHost: NSView?

    private func removeHoverArea() {
        if let hoverArea { hoverHost?.removeTrackingArea(hoverArea) }
        hoverArea = nil
        hoverHost = nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        removeHoverArea()
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Put the expanded hover rectangle on the parent so AppKit does not
        // clip it to the button's visible bounds. Clicks keep their native area.
        guard let host = superview else { removeHoverArea(); return }
        let rect = convert(hoverBounds, to: host)
        if hoverHost === host, hoverArea?.rect == rect { return }
        removeHoverArea()
        let area = NSTrackingArea(rect: rect,
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        host.addTrackingArea(area)
        hoverHost = host
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
