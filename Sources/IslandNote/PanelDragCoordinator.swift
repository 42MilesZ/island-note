import AppKit
import OSLog

/// Moves the existing window, while contour, tether and shadow share one animation clock.
@MainActor
final class PanelDragCoordinator {
    private struct Surface: Equatable {
        var floating: CGFloat = 0
        var lift: CGFloat = 0
        var pull: CGFloat = 0
        var connection: CGFloat = 0
        var welcome: CGFloat = 0

        func interpolated(to b: Surface, progress t: CGFloat) -> Surface {
            Surface(floating: floating + (b.floating - floating) * t,
                    lift: lift + (b.lift - lift) * t,
                    pull: pull + (b.pull - pull) * t,
                    connection: connection + (b.connection - connection) * t,
                    welcome: welcome + (b.welcome - welcome) * t)
        }
    }
    private struct Transition {
        let start: Surface
        let end: Surface
        let began: TimeInterval
        let duration: TimeInterval
    }
    private struct Flight {
        let start: NSPoint
        let end: NSPoint
        let began: TimeInterval
        let duration: TimeInterval
        let dock: Bool
        let collapse: Bool
        let haptic: Bool
    }
    private struct Drag {
        let mouse: NSPoint
        let origin: NSPoint
        let rectAtGrab: NSRect
        var lastMouse: NSPoint
        let startedFloating: Bool
        let interruptedFlight: Bool
        let surfaceAtGrab: Surface
        var moved = false
    }

    private let panel: IslandPanel
    private let mask: CAShapeLayer
    private let shadow: CALayer
    private var anchorRect: NSRect
    private var dockOrigin: NSPoint
    private let getRect: () -> NSRect
    private let onDock: (Bool) -> Void
    private let onFloatingChange: (Bool) -> Void
    private let getTargetRect: () -> NSRect
    private let overlay: NSPanel
    private let anchor = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private let bridge = CAShapeLayer()
    private let logger = Logger(subsystem: "local.projects.island-note", category: "PanelDrag")
    private var surface = Surface()
    private var handSurface: Surface?
    private var transition: Transition?
    private var flight: Flight?
    private var drag: Drag?
    private var timer: Timer?
    private var preview = false
    private var wantsCollapse = false
    private(set) var isFloating = false

    var isInteracting: Bool { drag != nil || flight != nil }
    var isDocking: Bool { flight?.dock == true }
    var isDragging: Bool { drag != nil }
    var preventsCollapse: Bool { isFloating || isInteracting }
    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(panel: IslandPanel, mask: CAShapeLayer, shadow: CALayer, anchorRect: NSRect,
         dockOrigin: NSPoint, getRect: @escaping () -> NSRect, onDock: @escaping (Bool) -> Void,
         getTargetRect: (() -> NSRect)? = nil, onFloatingChange: @escaping (Bool) -> Void = { _ in }) {
        self.panel = panel
        self.mask = mask
        self.shadow = shadow
        self.anchorRect = anchorRect
        self.dockOrigin = dockOrigin
        self.getRect = getRect
        self.onDock = onDock
        self.getTargetRect = getTargetRect ?? getRect
        self.onFloatingChange = onFloatingChange
        let overlayRect = NSRect(x: anchorRect.midX - 450, y: anchorRect.maxY - 190, width: 900, height: 190)
        overlay = NSPanel(contentRect: overlayRect, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        overlay.level = .screenSaver
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: overlayRect.size))
        view.wantsLayer = true
        overlay.contentView = view
        anchor.fillColor = NSColor.black.cgColor
        bridge.fillColor = NSColor.black.cgColor
        highlight.fillColor = NSColor.white.withAlphaComponent(0.10).cgColor
        view.layer?.addSublayer(bridge)
        view.layer?.addSublayer(anchor)
        view.layer?.addSublayer(highlight)
    }

    func begin(at mouse: NSPoint) {
        let wasFlying = flight != nil
        advance()
        flight = nil
        if wasFlying { transition = nil }
        wantsCollapse = false
        drag = Drag(mouse: mouse, origin: panel.frame.origin, rectAtGrab: getRect(), lastMouse: mouse, startedFloating: isFloating,
                    interruptedFlight: wasFlying, surfaceAtGrab: visibleSurface())
        preview = PanelDocking.isNearIsland(header: PanelDocking.headerContact(rect: screenRect(), island: anchorRect),
                                            island: anchorRect)
        if wasFlying { logger.debug("Docking interrupted by a new drag") }
        logger.debug("Panel header grabbed")
        if isFloating { onFloatingChange(true) }
        // Taking hold never changes text focus or selection.
    }

    func move(to mouse: NSPoint) {
        guard var drag else { return }
        let distance = PanelDocking.distance(mouse, drag.mouse)
        guard drag.moved || distance >= PanelDocking.dragThreshold else { return }
        drag.moved = true
        drag.lastMouse = mouse
        self.drag = drag
        if !isFloating, distance >= PanelDocking.separationDistance {
            isFloating = true
            panel.level = .floating
            onFloatingChange(true)
            Haptics.detach()
            logger.info("Panel detached")
        }
        let raw = grabbedOrigin(drag, at: mouse)
        let rawRect = getRect().offsetBy(dx: raw.x, dy: raw.y)
        let header = PanelDocking.headerContact(rect: rawRect, island: anchorRect)
        let previousPreview = preview
        preview = PanelDocking.isNearIsland(header: header, island: anchorRect, wasNear: preview)
        if preview != previousPreview {
            Haptics.dockBoundary()
            logger.info("Docking range: \(self.preview ? "entered" : "left", privacy: .public)")
        }
        let attraction = PanelDocking.attraction(header: header, island: anchorRect)
        // Magnetic bias is small and reversible; the window still follows every mouse delta.
        let bias = min(5, attraction * 5)
        let origin = NSPoint(x: raw.x + (anchorRect.midX - header.x) * bias / 150,
                             y: raw.y + bias)
        panel.setFrameOrigin(origin)
        overlay.orderFrontRegardless()
        let progress = min(1, distance / PanelDocking.separationDistance)
        // Geometry follows the hand directly. Only lift/settling is time-based;
        // retargeting an easing animation on every mouse delta would lag behind.
        let stretch = drag.startedFloating ? 0 : sin(progress * .pi) * 10
        let geometry = Surface(floating: drag.startedFloating ? 1 : progress,
                               pull: reducedMotion ? 0 : stretch + attraction * 10 * (drag.startedFloating ? 1 : progress),
                               connection: reducedMotion ? 0 : max(drag.startedFloating ? 0 : 1 - progress, attraction),
                               welcome: reducedMotion ? 0 : attraction)
        handSurface = drag.surfaceAtGrab.interpolated(to: geometry, progress: min(1, distance / 24))
        animateSurface(to: Surface(floating: 1, lift: 1), duration: 0.14)
        render()
    }

    func end(at mouse: NSPoint) {
        move(to: mouse)
        guard let drag else { return }
        releaseHandSurface()
        self.drag = nil
        NSCursor.arrow.set()
        guard drag.moved else {
            if isFloating { animateSurface(to: Surface(floating: 1), duration: 0.2) }
            else if drag.interruptedFlight { dock(collapse: false, haptic: false) }
            return
        }
        let rect = screenRect()
        let header = PanelDocking.headerContact(rect: rect, island: anchorRect)
        let shouldDock = !isFloating || PanelDocking.isNearIsland(header: header, island: anchorRect, wasNear: preview)
        logger.info("Panel released: dock=\(shouldDock, privacy: .public), header gap=\(header.y - self.anchorRect.midY, privacy: .public)")
        if shouldDock {
            dock(collapse: false, haptic: isFloating)
        } else {
            preview = false
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? panel.screen ?? NSScreen.main
            let origin = screen.map { PanelDocking.constrainedOrigin(panel.frame.origin, rect: getTargetRect(), screen: $0.visibleFrame) }
                ?? panel.frame.origin
            fly(to: origin, dock: false, collapse: false, haptic: false)
            animateSurface(to: Surface(floating: 1), duration: 0.26)
            logger.info("Floating panel released")
        }
    }

    func cancelAndDock(collapse: Bool) {
        wantsCollapse = collapse
        releaseHandSurface()
        drag = nil
        NSCursor.arrow.set()
        dock(collapse: collapse, haptic: isFloating)
    }

    private func dock(collapse: Bool, haptic: Bool) {
        preview = false
        overlay.orderFrontRegardless()
        fly(to: dockOrigin, dock: true, collapse: collapse, haptic: haptic)
        onFloatingChange(false)
        animateSurface(to: Surface(connection: reducedMotion ? 0 : 1), duration: flight?.duration ?? 0)
        logger.info("Panel returning to island")
    }

    private func fly(to origin: NSPoint, dock: Bool, collapse: Bool, haptic: Bool) {
        advance()
        let distance = PanelDocking.distance(panel.frame.origin, origin)
        let duration = reducedMotion ? 0 : min(0.42, max(0.24, Double(distance / 1600)))
        flight = Flight(start: panel.frame.origin, end: origin, began: ProcessInfo.processInfo.systemUptime,
                        duration: duration, dock: dock, collapse: collapse, haptic: haptic)
        startClock()
    }

    private func animateSurface(to target: Surface, duration: TimeInterval) {
        // Repeated mouse events must not restart an identical lift/rounding transition.
        guard transition?.end != target else { return }
        advanceSurface()
        guard surface != target else { return }
        transition = Transition(start: surface, end: target, began: ProcessInfo.processInfo.systemUptime,
                                duration: reducedMotion ? 0 : duration)
        startClock()
    }

    private func startClock() {
        guard timer == nil else { return }
        let clock = Timer(timeInterval: 1 / Double(max(60, panel.screen?.maximumFramesPerSecond ?? 60)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    private func eased(_ elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
        let t = duration == 0 ? 1 : min(1, max(0, elapsed / duration))
        return CGFloat(t * t * (3 - 2 * t)) // Explicit ease in/out.
    }

    private func advanceSurface() {
        guard let transition else { return }
        let now = ProcessInfo.processInfo.systemUptime
        surface = transition.start.interpolated(to: transition.end,
                                               progress: eased(now - transition.began, duration: transition.duration))
        if now - transition.began >= transition.duration { self.transition = nil }
    }

    private func visibleSurface() -> Surface {
        guard var handSurface else { return surface }
        handSurface.lift = surface.lift
        return handSurface
    }

    private func releaseHandSurface() {
        advanceSurface()
        if handSurface != nil {
            surface = visibleSurface()
            handSurface = nil
            transition = nil
        }
    }

    private func advance() {
        advanceSurface()
        guard let flight else { return }
        let t = eased(ProcessInfo.processInfo.systemUptime - flight.began, duration: flight.duration)
        panel.setFrameOrigin(NSPoint(x: flight.start.x + (flight.end.x - flight.start.x) * t,
                                     y: flight.start.y + (flight.end.y - flight.start.y) * t))
    }

    private func tick() {
        advance()
        render()
        if let flight, ProcessInfo.processInfo.systemUptime - flight.began >= flight.duration {
            self.flight = nil
            if flight.dock {
                // Confirm the actual window, rather than treating elapsed time as arrival.
                panel.setFrameOrigin(flight.end)
                if PanelDocking.distance(panel.frame.origin, flight.end) > 1 {
                    logger.error("Window did not reach its docking origin")
                    isFloating = true
                    onFloatingChange(true)
                    animateSurface(to: Surface(floating: 1), duration: 0.18)
                    return
                }
                isFloating = false
                surface = Surface()
                transition = nil
                panel.level = .screenSaver
                overlay.orderOut(nil)
                render()
                if flight.haptic { Haptics.dock() }
                logger.info("Panel docked")
                let collapse = flight.collapse || wantsCollapse
                wantsCollapse = false
                onDock(collapse)
            } else {
                recoverDisplay()
            }
        }
        if transition == nil, flight == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    func path(for rect: NSRect) -> CGPath {
        let visible = visibleSurface()
        return PanelContour.path(rect, floating: visible.floating, pull: visible.pull,
                          towardX: anchorRect.midX - panel.frame.minX)
    }

    private func screenRect() -> NSRect { getRect().offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) }

    /// The contour and its shadow use the same path; the text viewport never deforms.
    private func render() {
        let path = path(for: getRect())
        let visible = visibleSurface()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.removeAnimation(forKey: "path")
        mask.path = path
        shadow.shadowPath = path
        shadow.shadowOpacity = Float(visible.floating * (0.22 + 0.07 * visible.lift))
        shadow.shadowRadius = 14 + 20 * visible.lift
        shadow.shadowOffset = CGSize(width: 0, height: -6 - 12 * visible.lift)
        renderConnection()
        CATransaction.commit()
    }

    private func renderConnection() {
        let visible = visibleSurface()
        let o = overlay.frame.origin
        let r = anchorRect.offsetBy(dx: -o.x, dy: -o.y)
        let body = screenRect().offsetBy(dx: -o.x, dy: -o.y)
        let meetX = min(r.maxX - 28, max(r.minX + 28, body.midX))
        let bulge = visible.welcome * 7
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + 10, y: r.maxY - 10), control: CGPoint(x: r.minX + 10, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 10, y: r.minY + 20))
        p.addQuadCurve(to: CGPoint(x: r.minX + 30, y: r.minY), control: CGPoint(x: r.minX + 10, y: r.minY))
        p.addCurve(to: CGPoint(x: meetX, y: r.minY - bulge),
                   control1: CGPoint(x: r.minX + 45, y: r.minY), control2: CGPoint(x: meetX - 16, y: r.minY - bulge))
        p.addCurve(to: CGPoint(x: r.maxX - 30, y: r.minY),
                   control1: CGPoint(x: meetX + 16, y: r.minY - bulge), control2: CGPoint(x: r.maxX - 45, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 10, y: r.minY + 20), control: CGPoint(x: r.maxX - 10, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 10, y: r.maxY - 10))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - 10, y: r.maxY))
        p.closeSubpath()
        anchor.path = p
        highlight.path = CGPath(roundedRect: r.insetBy(dx: 25, dy: 8), cornerWidth: 7, cornerHeight: 7, transform: nil)
        highlight.opacity = Float(visible.welcome)
        bridge.path = PanelContour.bridgePath(island: r, body: body,
                                              connection: reducedMotion ? 0 : visible.connection)
        bridge.opacity = 1
    }

    /// Resizing shares the existing outline animation, including the floating shadow.
    func updateShadow(path: CGPath) {
        shadow.shadowPath = path
    }

    /// Size morphing and live edge resizing feed the same contour/shadow renderer.
    func viewportDidChange() {
        if let drag, drag.moved { move(to: drag.lastMouse) }
        else {
            // A held floating header keeps its grip even before the drag threshold.
            if let drag, isFloating { panel.setFrameOrigin(grabbedOrigin(drag, at: drag.lastMouse)) }
            render()
        }
    }

    private func grabbedOrigin(_ drag: Drag, at mouse: NSPoint) -> NSPoint {
        let rect = getRect()
        let grip = min(1, max(0, (drag.mouse.x - drag.origin.x - drag.rectAtGrab.minX) / drag.rectAtGrab.width))
        return NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x
                         + drag.rectAtGrab.minX + drag.rectAtGrab.width * grip - rect.minX - rect.width * grip,
                       y: drag.origin.y + mouse.y - drag.mouse.y + drag.rectAtGrab.maxY - rect.maxY)
    }

    /// A pinch may start immediately after mouse-up. Finish the release animation
    /// before the resize spring takes ownership of the same mask and shadow.
    func prepareForResize() -> Bool {
        guard drag == nil, flight?.dock != true else { return false }
        guard isFloating, flight != nil || transition != nil else { return true }
        advance()
        if let flight { panel.setFrameOrigin(flight.end) }
        flight = nil
        transition = nil
        handSurface = nil
        surface = Surface(floating: 1)
        timer?.invalidate()
        timer = nil
        render()
        return true
    }

    func recoverDisplay(rect: NSRect? = nil) {
        guard isFloating, !isInteracting, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(PanelDocking.constrainedOrigin(panel.frame.origin, rect: rect ?? getRect(), screen: screen.visibleFrame))
    }

    func updateDock(anchorRect: NSRect, origin: NSPoint) {
        self.anchorRect = anchorRect
        dockOrigin = origin
        overlay.setFrameOrigin(NSPoint(x: anchorRect.midX - 450, y: anchorRect.maxY - 190))
        if isInteracting { cancelAndDock(collapse: false) }
        else if isFloating { recoverDisplay() }
        else { panel.setFrameOrigin(origin) }
    }

    deinit {
        timer?.invalidate()
        let window = overlay
        DispatchQueue.main.async { window.orderOut(nil) }
    }
}
