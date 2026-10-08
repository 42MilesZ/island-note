import AppKit

struct PanelResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let bottom = Self(rawValue: 4)
    static let top = Self(rawValue: 8)
}

enum FloatingPanelLayout {
    static let minimum = NSSize(width: 320, height: 280)
    static let maximum = NSSize(width: 1200, height: 1000)

    static func clamped(_ size: NSSize, maximum: NSSize) -> NSSize {
        NSSize(width: min(maximum.width, max(minimum.width, size.width)),
               height: min(maximum.height, max(minimum.height, size.height)))
    }

    /// Native magnification changes the current size proportionally. Clamp each
    /// delta so reversing at a limit responds immediately without accumulated overshoot.
    static func magnified(_ rect: NSRect, delta: CGFloat, maximum: NSSize,
                          screen: NSRect) -> (rect: NSRect, limited: Bool) {
        guard delta.isFinite, rect.width > 0, rect.height > 0,
              maximum.width > 0, maximum.height > 0, screen.width > 0, screen.height > 0 else { return (rect, false) }
        let available = NSSize(width: min(maximum.width, screen.width), height: min(maximum.height, screen.height))
        let upper = min(available.width / rect.width, available.height / rect.height)
        let lower = min(upper, max(minimum.width / rect.width, minimum.height / rect.height))
        let requested = 1 + delta
        let scale = min(upper, max(lower, requested))
        let size = NSSize(width: min(available.width, rect.width * scale), height: min(available.height, rect.height * scale))
        var result = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        result.origin = PanelDocking.constrainedOrigin(result.origin, rect: NSRect(origin: .zero, size: size), screen: screen)
        return (result, abs(scale - requested) > 0.00001)
    }

    /// The opposite edge stays fixed; dragging a corner changes both axes.
    static func resized(_ rect: NSRect, edges: PanelResizeEdges, delta: NSPoint,
                        maximum: NSSize, screen: NSRect) -> NSRect {
        var result = rect
        if edges.contains(.left) {
            let maxWidth = min(maximum.width, rect.maxX - screen.minX)
            let width = min(maxWidth, max(min(minimum.width, maxWidth), rect.width - delta.x))
            result.origin.x = rect.maxX - width
            result.size.width = width
        } else if edges.contains(.right) {
            let maxWidth = min(maximum.width, screen.maxX - rect.minX)
            result.size.width = min(maxWidth, max(min(minimum.width, maxWidth), rect.width + delta.x))
        }
        if edges.contains(.bottom) {
            let maxHeight = min(maximum.height, rect.maxY - screen.minY)
            let height = min(maxHeight, max(min(minimum.height, maxHeight), rect.height - delta.y))
            result.origin.y = rect.maxY - height
            result.size.height = height
        } else if edges.contains(.top) {
            let maxHeight = min(maximum.height, screen.maxY - rect.minY)
            result.size.height = min(maxHeight, max(min(minimum.height, maxHeight), rect.height + delta.y))
        }
        return result
    }
}

final class PanelResizeHandle: NSView {
    let edges: PanelResizeEdges
    var onBegin: ((NSPoint) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: ((NSPoint) -> Void)?
    var excludedRect = NSRect.zero
    private var hoverAreas: [NSTrackingArea] = []

    var interactiveRects: [NSRect] {
        let cut = bounds.intersection(excludedRect)
        guard !cut.isEmpty else { return [bounds] }
        return [NSRect(x: bounds.minX, y: bounds.minY, width: cut.minX - bounds.minX, height: bounds.height),
                NSRect(x: cut.maxX, y: bounds.minY, width: bounds.maxX - cut.maxX, height: bounds.height),
                NSRect(x: cut.minX, y: bounds.minY, width: cut.width, height: cut.minY - bounds.minY),
                NSRect(x: cut.minX, y: cut.maxY, width: cut.width, height: bounds.maxY - cut.maxY)].filter { !$0.isEmpty }
    }

    func containsResizePoint(_ point: NSPoint) -> Bool { interactiveRects.contains { $0.contains(point) } }

    init(edges: PanelResizeEdges) {
        self.edges = edges
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func diagonalCursor(rising: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let path = NSBezierPath()
            let points: [NSPoint] = [NSPoint(x: 4, y: 4), NSPoint(x: 16, y: 16),
                                    NSPoint(x: 4, y: 10), NSPoint(x: 4, y: 4), NSPoint(x: 10, y: 4),
                                    NSPoint(x: 10, y: 16), NSPoint(x: 16, y: 16), NSPoint(x: 16, y: 10)]
            let mapped = points.map { NSPoint(x: $0.x, y: rising ? $0.y : 20 - $0.y) }
            path.move(to: mapped[0]); path.line(to: mapped[1])
            path.move(to: mapped[2]); path.line(to: mapped[3]); path.line(to: mapped[4])
            path.move(to: mapped[5]); path.line(to: mapped[6]); path.line(to: mapped[7])
            path.lineCapStyle = .round
            NSColor.black.setStroke(); path.lineWidth = 3.5; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }
    private static let risingCursor = diagonalCursor(rising: true)
    private static let fallingCursor = diagonalCursor(rising: false)
    var resizeCursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            default: position = .bottomRight
            }
            return .frameResize(position: position, directions: [.inward, .outward])
        }
        if edges.intersection([.left, .right]).isEmpty { return .resizeUpDown }
        if edges.intersection([.top, .bottom]).isEmpty { return .resizeLeftRight }
        return edges == [.left, .bottom] || edges == [.right, .top] ? Self.risingCursor : Self.fallingCursor
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        for rect in interactiveRects { addCursorRect(rect, cursor: resizeCursor) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in hoverAreas { removeTrackingArea(area) }
        hoverAreas.removeAll()
        for rect in interactiveRects {
            // activeAlways delivers entered/moved even while the floating window
            // is inactive. cursorUpdate uses a separate active-app area per AppKit.
            for options: NSTrackingArea.Options in [[.mouseEnteredAndExited, .mouseMoved, .activeAlways], [.cursorUpdate, .activeInActiveApp]] {
                let area = NSTrackingArea(rect: rect, options: options, owner: self, userInfo: nil)
                addTrackingArea(area)
                hoverAreas.append(area)
            }
        }
    }
    private func updateHoverCursor(_ event: NSEvent) {
        guard let owner = superview as? PanelResizeView, owner.isEnabled,
              containsResizePoint(convert(event.locationInWindow, from: nil)) else { return }
        resizeCursor.set()
    }
    override func cursorUpdate(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseEntered(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseExited(with event: NSEvent) { window?.invalidateCursorRects(for: self) }
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func mouseDown(with event: NSEvent) { resizeCursor.set(); onBegin?(screenPoint(event)) }
    override func mouseDragged(with event: NSEvent) { onMove?(screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { onEnd?(screenPoint(event)); window?.invalidateCursorRects(for: self) }
}

/// A transparent sibling of the editor: only its narrow edges receive input.
final class PanelResizeView: NSView {
    static let outsideReach: CGFloat = 14
    private static let insideReach: CGFloat = 34
    var onBegin: ((PanelResizeEdges, NSPoint) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: ((NSPoint) -> Void)?
    var isEnabled = false {
        didSet { isHidden = !isEnabled }
    }
    var panelRect = NSRect.zero { didSet { layoutHandles() } }
    private var handles: [PanelResizeHandle] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        let edgeSets: [PanelResizeEdges] = [.left, .right, .bottom, .top, [.left, .bottom], [.right, .bottom], [.left, .top], [.right, .top]]
        for edges in edgeSets {
            let handle = PanelResizeHandle(edges: edges)
            handle.onBegin = { [weak self] point in self?.onBegin?(edges, point) }
            handle.onMove = { [weak self] point in self?.onMove?(point) }
            handle.onEnd = { [weak self] point in self?.onEnd?(point) }
            handles.append(handle)
            addSubview(handle)
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        return handles.reversed().first { $0.containsResizePoint(convert(point, to: $0)) }
    }

    func resizeCursor(at point: NSPoint) -> NSCursor? { (hitTest(point) as? PanelResizeHandle)?.resizeCursor }

    private func layoutHandles() {
        let r = panelRect
        let inside = Self.insideReach, outside = Self.outsideReach
        // Subtract the editor's full status-button footprint from both hover and clicks.
        let statusRect = NSRect(x: r.maxX - 39, y: r.maxY - 31, width: 24, height: 24)
        for handle in handles {
            switch handle.edges {
            case .left: handle.frame = NSRect(x: r.minX - 7, y: r.minY + inside, width: 14, height: max(0, r.height - inside * 2))
            case .right: handle.frame = NSRect(x: r.maxX - 7, y: r.minY + inside, width: 14, height: max(0, r.height - inside * 2))
            case .bottom: handle.frame = NSRect(x: r.minX + inside, y: r.minY - 7, width: max(0, r.width - inside * 2), height: 14)
            case .top: handle.frame = NSRect(x: r.minX + inside, y: r.maxY - 7, width: max(0, r.width - inside * 2), height: 14)
            default:
                handle.frame = NSRect(x: handle.edges.contains(.left) ? r.minX - outside : r.maxX - inside,
                                      y: handle.edges.contains(.bottom) ? r.minY - outside : r.maxY - inside,
                                      width: inside + outside, height: inside + outside)
            }
            handle.excludedRect = statusRect.offsetBy(dx: -handle.frame.minX, dy: -handle.frame.minY)
            handle.updateTrackingAreas()
            window?.invalidateCursorRects(for: handle)
        }
    }
}
