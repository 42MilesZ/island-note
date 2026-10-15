import AppKit

final class StatusIndicatorButton: NSButton {
    override class var cellClass: AnyClass? {
        get { StatusIndicatorCell.self }
        set { }
    }
    static let hoverPadding: CGFloat = 6
    var onHover: ((Bool) -> Void)?
    var onHighlight: ((Bool) -> Void)?
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
    // Route the layer-only control through AppKit's cell-based mouse tracking.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onHighlight?(true)
        defer { onHighlight?(false) }
        super.mouseDown(with: event)
    }
}

/// The button is drawn by owned layers, so its native cell has no title/image.
/// Explicit content hit testing keeps normal AppKit mouse-up and drag-out tracking.
private final class StatusIndicatorCell: NSButtonCell {
    override var isHighlighted: Bool {
        didSet { (controlView as? StatusIndicatorButton)?.onHighlight?(isHighlighted) }
    }

    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}
