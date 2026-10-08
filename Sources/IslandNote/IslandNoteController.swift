import AppKit
import OSLog

/// 命中放行：只在当前可见形状内接管点击，其余穿透到下方（菜单栏照常可点）。
final class IslandView: NSView {
    override var isFlipped: Bool { false } // 原点左下，顶 = maxY
    var hitRect = NSRect.zero
    var onAccessibilityPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onAccessibilityPress else { return false }
        onAccessibilityPress()
        return true
    }

    override func accessibilityFrame() -> NSRect {
        guard let window, !hitRect.isEmpty else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(hitRect, to: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !hitRect.isEmpty && !hitRect.contains(point) { return nil }
        return super.hitTest(point)
    }
}

/// 无边框、可成为 key 的岛体面板（同 Spirit / DynamicNotchKit 窗口配方）。
final class IslandPanel: NSPanel {
    // The transparent shadow gutter may cross screen edges. AppKit must not
    // reposition this canvas; the visible contour is constrained explicitly.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onSyncSettings: (() -> Void)?

    /// nonactivatingPanel 下菜单 keyEquivalent 不稳，这里显式把编辑命令派给 firstResponder；
    /// 其余 ⌘ 组合吞掉，避免系统「滴」声。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "c":
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) || true
        case "x":
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) || true
        case "v":
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) || true
        case "b":
            NotificationCenter.default.post(name: .islandNoteBold, object: nil)
            return true
        case "i":
            NotificationCenter.default.post(name: .islandNoteItalic, object: nil)
            return true
        case "a":
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) || true
        case "z":
            let um = (firstResponder as? NSText)?.undoManager
                ?? (firstResponder as? NSView)?.window?.firstResponder?.undoManager
            if flags.contains(.shift) {
                if um?.canRedo == true { um?.redo() }
            } else {
                if um?.canUndo == true { um?.undo() }
            }
            return true
        case ",":
            onSyncSettings?()
            return true
        case "q":
            NSApp.terminate(nil)
            return true
        default:
            return true
        }
    }
}

/// 停靠时顶边固定在屏幕最顶；拖出时保留同一个编辑器，由拖拽协调器连续移动轮廓。
@MainActor
final class IslandNoteController: NSObject {
    private let store: NoteStore
    #if !ISLAND_TESTFLIGHT
    private var sync: FlomoSync?
    #endif
    private var showingSyncSettings = false

    // 窗口与岛体
    private var panel: IslandPanel!
    private var island: IslandView!
    private var maskLayer: CAShapeLayer!
    private var editor: NoteEditorView!
    private var hitGate: IslandView!
    private var shadowLayer: CALayer!
    private var dragInteraction: PanelDragCoordinator!
    private var displayObservation: NSObjectProtocol?
    private var resizeHandles: PanelResizeView!

    // 几何
    private var screenFrame = NSRect.zero
    private var notchW: CGFloat = 200
    private var notchH: CGFloat = 32
    private var eW: CGFloat = 460
    private var panelH: CGFloat = 240
    private var gutter: CGFloat = 16
    private var eH: CGFloat = 256
    private var canvasTop: CGFloat { eH - gutter }

    private var restRect = NSRect.zero
    private var hoverRect = NSRect.zero
    private var expandedRect = NSRect.zero
    private var panelSize: PanelSize = .standard
    private var pinch = PanelPinch()
    private var pendingPinchSize: PanelSize?
    private let diagnostics: InteractionDiagnostics
    private var resizeTimer: Timer?
    private var floatingSize: NSSize?
    private var targetViewportSize: NSSize?
    private struct EdgeResize {
        let edges: PanelResizeEdges
        let mouse: NSPoint
        let rect: NSRect
        let maximum: NSSize
        let screen: NSRect
    }
    private var edgeResize: EdgeResize?
    private let logger = Logger(subsystem: "local.projects.island-note", category: "PanelResize")

    private let compactTopR: CGFloat = 10
    private let compactBotR: CGFloat = 20
    private let expandedTopR: CGFloat = 10
    private let expandedBotR: CGFloat = 32

    enum Mode { case rest, hover, expanded }
    private(set) var mode: Mode = .rest

    private var pendingCollapse: DispatchWorkItem?
    private var finishingCollapse = false
    private var monitors: [Any] = []

    init(store: NoteStore, enableSync: Bool = true, diagnostics: InteractionDiagnostics? = nil) {
        self.store = store
        self.diagnostics = diagnostics ?? (enableSync ? .shared : InteractionDiagnostics(defaults: nil, enabled: false))
        super.init()
        installMainMenu()
        setup()
        bindStore()
        self.diagnostics.record(.checkpoint, state: diagnosticState())
        #if !ISLAND_TESTFLIGHT
        if enableSync { setupSync() }
        #endif
    }

    /// 主菜单 Edit：让 ⌘C/V/X/A/Z 走标准 responder，少一层拦截。
    private func installMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Island Note")
        #if !ISLAND_TESTFLIGHT
        let syncItem = NSMenuItem(title: "Flomo Sync…", action: #selector(showSyncSettings), keyEquivalent: ",")
        syncItem.target = self
        appMenu.addItem(syncItem)
        #endif
        let quit = NSMenuItem(title: "Quit Island Note", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        NSApp.mainMenu = main
    }

    // MARK: - 几何辅助

    private func notchScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func screenRect(_ r: NSRect) -> NSRect {
        let o = panel.frame.origin
        return NSRect(x: o.x + r.minX, y: o.y + r.minY, width: r.width, height: r.height)
    }

    private func screenPoint(for event: NSEvent?) -> NSPoint {
        guard let event, let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func radii(for m: Mode) -> (CGFloat, CGFloat) {
        switch m {
        case .expanded: return (expandedTopR, expandedBotR)
        default: return (compactTopR, compactBotR)
        }
    }

    private func rect(for m: Mode) -> NSRect {
        switch m {
        case .rest: return restRect
        case .hover: return hoverRect
        case .expanded: return expandedRect
        }
    }

    /// 灵动岛轮廓：顶边全宽 + 顶部微内凹、底部大圆角。顶 = rect.maxY（所有形态共用）。
    private func notchPath(_ r: CGRect, topR: CGFloat, botR: CGFloat) -> CGPath {
        PanelContour.path(r, floating: 0, topRadius: topR, bottomRadius: botR)
    }

    // MARK: - Setup

    private func setup() {
        let screen = notchScreen()
        let sf = screen.frame
        screenFrame = sf
        notchH = max(screen.safeAreaInsets.top, 32)
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let w = sf.width - l.width - r.width
            if w > 40 { notchW = w }
        }

        // 灵动岛比例取中：略扁略宽，不过分
        let barH: CGFloat = 33
        panelH = PanelSize.standard.dimensions.height
        // Space for the lifted shadow on all sides, including above a floating panel.
        gutter = 64
        // The canvas also accommodates user-sized floating panels and their shadows.
        eW = min(FloatingPanelLayout.maximum.width + gutter * 2, sf.width + gutter * 2)
        eH = min(FloatingPanelLayout.maximum.height + gutter * 2, sf.height + gutter * 2)

        let winFrame = NSRect(x: sf.midX - eW / 2, y: sf.maxY - canvasTop, width: eW, height: eH)

        // 可见形状顶边 = canvasTop（屏幕最顶），上方透明区域留给悬浮阴影。
        expandedRect = expandedFrame(for: .standard)
        let restW = max(notchW * 1.06, 210) - 11
        restRect = NSRect(x: (eW - restW) / 2, y: canvasTop - barH, width: restW, height: barH)
        hoverRect = NSRect(
            x: (eW - restW - 14) / 2,
            y: canvasTop - barH - 4,
            width: restW + 14,
            height: barH + 4
        )

        panel = IslandPanel(
            contentRect: winFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        #if !ISLAND_TESTFLIGHT
        panel.onSyncSettings = { [weak self] in self?.showSyncSettings() }
        #endif
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false

        let content = IslandView(frame: NSRect(origin: .zero, size: winFrame.size))
        content.wantsLayer = true
        content.hitRect = restRect
        hitGate = content

        shadowLayer = CALayer()
        shadowLayer.frame = content.bounds
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0
        content.layer?.addSublayer(shadowLayer)

        island = IslandView(frame: NSRect(origin: .zero, size: winFrame.size))
        island.wantsLayer = true
        island.autoresizesSubviews = true
        island.layer?.backgroundColor = NSColor.black.cgColor
        maskLayer = CAShapeLayer()
        maskLayer.frame = island.bounds
        maskLayer.path = notchPath(restRect, topR: compactTopR, botR: compactBotR)
        island.layer?.mask = maskLayer
        island.hitRect = restRect
        island.setAccessibilityElement(true)
        island.setAccessibilityRole(.button)
        island.setAccessibilityLabel("Open Island Note")
        island.onAccessibilityPress = { [weak self] in self?.expand() }

        editor = NoteEditorView(frame: expandedRect)
        editor.autoresizingMask = []
        editor.onTextChanged = { [weak self] text in
            self?.store.save(text)
        }
        editor.onRequestCollapse = { [weak self] in
            self?.collapse()
        }
        editor.onRequestQuit = {
            NSApp.terminate(nil)
        }
        #if !ISLAND_TESTFLIGHT
        editor.onRequestSync = { [weak self] in self?.showSyncSettings() }
        #endif
        // 编辑器只覆盖可见形状（expandedRect）：底边 = 遮罩底边，
        // 原先铺满全窗口时底部 16px gutter 成了「滚得到但永远看不见」的死区。
        editor.frame = expandedRect
        editor.isHidden = true
        editor.alphaValue = 0
        island.addSubview(editor)

        content.addSubview(island)
        resizeHandles = PanelResizeView(frame: content.bounds)
        resizeHandles.panelRect = expandedRect
        content.addSubview(resizeHandles, positioned: .above, relativeTo: island)
        panel.contentView = content
        panel.orderFrontRegardless()

        dragInteraction = PanelDragCoordinator(panel: panel, mask: maskLayer, shadow: shadowLayer,
            anchorRect: restRect.offsetBy(dx: winFrame.minX, dy: winFrame.minY), dockOrigin: winFrame.origin,
            getRect: { [weak self] in self?.expandedRect ?? .zero },
            onDock: { [weak self] shouldCollapse in
                guard let self else { return }
                if shouldCollapse { self.pendingPinchSize = nil; self.collapse() }
                else if let size = self.pendingPinchSize {
                    self.pendingPinchSize = nil
                    self.resize(to: size)
                }
            }, getTargetRect: { [weak self] in
                guard let self else { return .zero }
                return self.viewportFrame(size: self.targetViewportSize ?? self.expandedRect.size)
            }, onFloatingChange: { [weak self] floating in self?.changeFloatingLayout(floating) })
        editor.dragHandle.onBegin = { [weak self] point in
            guard let self, self.mode == .expanded else { return }
            self.pendingCollapse?.cancel()
            self.pendingCollapse = nil
            // A new grab starts from the currently displayed intermediate viewport.
            self.stopViewportAnimation()
            self.pinch.reset()
            self.pendingPinchSize = nil
            self.editor.frame = self.expandedRect
            self.hitGate.hitRect = self.expandedRect
            self.island.hitRect = self.expandedRect
            self.dragInteraction.begin(at: point)
            self.diagnostics.record(.headerGrabbed, state: self.diagnosticState())
        }
        editor.dragHandle.onMove = { [weak self] in self?.dragInteraction.move(to: $0) }
        editor.dragHandle.onEnd = { [weak self] point in
            guard let self else { return }
            self.dragInteraction.end(at: point)
            self.diagnostics.record(.headerReleased, state: self.diagnosticState())
            if self.mode == .expanded, !self.dragInteraction.isFloating, !self.dragInteraction.isInteracting {
                self.animateViewport(to: self.panelSize.dimensions)
            }
        }
        resizeHandles.onBegin = { [weak self] edges, point in self?.beginEdgeResize(edges: edges, at: point) }
        resizeHandles.onMove = { [weak self] point in self?.moveEdgeResize(to: point) }
        resizeHandles.onEnd = { [weak self] point in self?.endEdgeResize(at: point) }
        displayObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockScreen() }
        }

        installMonitors()
    }

    private func bindStore() {
        store.onSaved = { [weak self] in
            self?.editor.flashSavedIndicator()
        }
        store.onSaveError = { [weak self] message in
            self?.editor.showSaveError(message)
        }
        do {
            editor.string = try store.load()
            editor.setEditingEnabled(true)
        } catch {
            editor.setEditingEnabled(false)
            editor.showSaveError("Could not open \(store.path): \(error.localizedDescription)")
        }
    }

    private func updateDockScreen() {
        let screen = notchScreen()
        screenFrame = screen.frame
        notchW = 200
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let width = screenFrame.width - l.width - r.width
            if width > 40 { notchW = width }
        }
        let width = max(notchW * 1.06, 210) - 11
        restRect = NSRect(x: (eW - width) / 2, y: canvasTop - 33, width: width, height: 33)
        hoverRect = restRect.insetBy(dx: -7, dy: 0)
        hoverRect.origin.y -= 4
        hoverRect.size.height += 4
        let origin = NSPoint(x: screenFrame.midX - eW / 2, y: screenFrame.maxY - canvasTop)
        dragInteraction.updateDock(anchorRect: restRect.offsetBy(dx: origin.x, dy: origin.y), origin: origin)
        if dragInteraction.isFloating, !dragInteraction.isInteracting {
            edgeResize = nil
            stopViewportAnimation()
            let fitted = FloatingPanelLayout.clamped(floatingSize ?? expandedRect.size, maximum: floatingMaximum())
            floatingSize = fitted
            applyViewport(size: fitted)
        }
        if !dragInteraction.preventsCollapse {
            hitGate.hitRect = rect(for: mode)
            island.hitRect = rect(for: mode)
            let (top, bottom) = radii(for: mode)
            maskLayer.path = mode == .expanded ? dragInteraction.path(for: expandedRect)
                : notchPath(rect(for: mode), topR: top, botR: bottom)
        }
    }

    deinit {
        resizeTimer?.invalidate()
        pendingCollapse?.cancel()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let displayObservation { NotificationCenter.default.removeObserver(displayObservation) }
    }

    private func installMonitors() {
        let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.handleHover()
        }
        let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] e in
            self?.handleHover(e)
            return e
        }
        let gc = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            self?.handleClick(e)
        }
        let lc = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            self?.handleClick(e)
            return e
        }
        let gr = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] e in
            self?.handleRightClick(e)
        }
        let lr = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] e in
            self?.handleRightClick(e)
            return e
        }
        let lk = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return self.editor.handleKey(e)
        }
        let lm = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] e in
            guard let self else { return e }
            guard e.window === self.panel else {
                self.diagnostics.record(.pinchReceived, state: self.diagnosticState(), delta: e.magnification, phase: e.phase)
                self.diagnostics.record(.wrongWindow, state: self.diagnosticState(), delta: e.magnification, phase: e.phase)
                if e.phase.contains(.ended) || e.phase.contains(.cancelled) { self.pinch.reset() }
                return e
            }
            return self.handleMagnify(e) ? nil : e
        }
        monitors = [g, l, gc, lc, gr, lr, lk, lm].compactMap { $0 }
    }

    private func expandedFrame(for size: PanelSize) -> NSRect { viewportFrame(size: size.dimensions) }

    private func viewportFrame(size: NSSize) -> NSRect {
        let width = min(size.width, eW - gutter * 2)
        let height = min(size.height, canvasTop - gutter)
        return NSRect(x: (eW - width) / 2, y: canvasTop - height, width: width, height: height)
    }

    private func floatingMaximum(screen: NSScreen? = nil) -> NSSize {
        let visible = (screen ?? panel.screen ?? notchScreen()).visibleFrame
        return NSSize(width: min(eW - gutter * 2, visible.width),
                      height: min(canvasTop - gutter, visible.height))
    }

    private func changeFloatingLayout(_ floating: Bool) {
        edgeResize = nil
        resizeHandles.isEnabled = floating
        if floating {
            let size = FloatingPanelLayout.clamped(floatingSize ?? panelSize.floatingDimensions,
                                                    maximum: floatingMaximum())
            floatingSize = size
            animateViewport(to: size)
        } else {
            animateViewport(to: panelSize.dimensions)
        }
        updateViewportHitAreas()
        diagnostics.record(.floatingChanged, state: diagnosticState())
    }

    private func handleMagnify(_ event: NSEvent) -> Bool {
        handleMagnification(delta: event.magnification, phase: event.phase, locationInWindow: event.locationInWindow)
    }

    func handleMagnification(delta: CGFloat, phase: NSEvent.Phase, locationInWindow: NSPoint) -> Bool {
        diagnostics.record(.pinchReceived, state: diagnosticState(), delta: delta, phase: phase)
        func reject(_ reason: InteractionDiagnosticReason) -> Bool {
            diagnostics.record(reason, state: diagnosticState(), delta: delta, phase: phase)
            if phase.contains(.ended) || phase.contains(.cancelled) { pinch.reset() }
            return false
        }
        guard mode == .expanded else { return reject(.panelClosed) }
        guard edgeResize == nil else { return reject(.edgeResizing) }
        guard !dragInteraction.isDragging else { return reject(.headerDragging) }
        // The editor is already visible while its opening contour is still animating.
        // Accept gestures on the editor, rather than only the smaller presentation mask.
        guard pinch.isActive || expandedRect.contains(locationInWindow) else { return reject(.outsidePanel) }
        if phase.contains(.began), pinch.isActive { diagnostics.record(.gestureInterrupted, state: diagnosticState()) }
        if !dragInteraction.isDocking { _ = dragInteraction.prepareForResize() }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        let current: PanelSize? = pendingPinchSize ?? (dragInteraction.isFloating && !dragInteraction.isDocking
            ? [PanelSize.standard, .large].first { $0.floatingDimensions == floatingSize }
            : panelSize)
        let evaluation = pinch.evaluate(delta: delta, phase: phase, size: current)
        if evaluation != .alreadyCommitted, evaluation != .waiting || phase.contains(.ended) {
            diagnostics.record(evaluation.reason, state: diagnosticState(), delta: delta, phase: phase)
        }
        if case let .resize(target) = evaluation {
            if dragInteraction.isDocking {
                pendingPinchSize = target
                diagnostics.record(.resizeQueued, state: diagnosticState())
            } else { resize(to: target) }
        }
        if phase.contains(.ended) || phase.contains(.cancelled) { diagnostics.record(.gestureFinished, state: diagnosticState()) }
        return true
    }

    private func resize(to size: PanelSize) {
        if dragInteraction.isFloating {
            let current = floatingSize ?? expandedRect.size
            let isPreset = [PanelSize.standard, .large].contains { $0.floatingDimensions == current }
            let scale: CGFloat = size == .large ? 1.2 : 1 / 1.2
            let requested = isPreset ? size.floatingDimensions
                : NSSize(width: current.width * scale, height: current.height * scale)
            let target = FloatingPanelLayout.clamped(requested, maximum: floatingMaximum())
            guard target != expandedRect.size else { diagnostics.record(.sizeLimit, state: diagnosticState()); return }
            floatingSize = target
            animateViewport(to: target)
        } else {
            guard size != panelSize else { diagnostics.record(.presetLimit, state: diagnosticState()); return }
            panelSize = size
            animateViewport(to: size.dimensions)
        }
        Haptics.resize()
        logger.info("Panel size target: \(self.targetViewportSize?.width ?? self.expandedRect.width, privacy: .public) x \(self.targetViewportSize?.height ?? self.expandedRect.height, privacy: .public)")
    }

    private func stopViewportAnimation(completed: Bool = false) {
        if let target = targetViewportSize {
            let reached = abs(target.width - expandedRect.width) < 0.5 && abs(target.height - expandedRect.height) < 0.5
            diagnostics.record(completed ? (reached ? .resizeCompleted : .resizeStalled) : .resizeInterrupted, state: diagnosticState())
        }
        resizeTimer?.invalidate()
        resizeTimer = nil
        targetViewportSize = nil
    }

    private func animateViewport(to requested: NSSize) {
        if targetViewportSize == requested { return }
        stopViewportAnimation()
        let target = viewportFrame(size: requested).size
        guard target != expandedRect.size else { return }
        let start = expandedRect.size
        targetViewportSize = target
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.32
        if duration == 0 { applyViewport(size: target); stopViewportAnimation(completed: true); return }
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / Double(max(60, panel.screen?.maximumFramesPerSecond ?? 60)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
                let eased = CGFloat(t * t * (3 - 2 * t))
                self.applyViewport(size: NSSize(width: start.width + (target.width - start.width) * eased,
                                                height: start.height + (target.height - start.height) * eased))
                if t >= 1 { self.stopViewportAnimation(completed: true) }
            }
        }
        resizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyViewport(size: NSSize) {
        expandedRect = viewportFrame(size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        editor.frame = expandedRect
        editor.layoutSubtreeIfNeeded()
        updateViewportHitAreas()
        if mode == .expanded {
            dragInteraction.viewportDidChange()
            dragInteraction.recoverDisplay(rect: expandedRect)
        }
        CATransaction.commit()
    }

    private func updateViewportHitAreas() {
        hitGate.hitRect = mode == .expanded && resizeHandles.isEnabled
            ? expandedRect.insetBy(dx: -6, dy: -6) : rect(for: mode)
        island.hitRect = rect(for: mode)
        resizeHandles.panelRect = expandedRect
    }

    func beginEdgeResize(edges: PanelResizeEdges, at mouse: NSPoint) {
        guard mode == .expanded, dragInteraction.isFloating, dragInteraction.prepareForResize() else { return }
        stopViewportAnimation()
        pinch.reset()
        dragInteraction.recoverDisplay()
        let screen = panel.screen ?? notchScreen()
        let fitted = FloatingPanelLayout.clamped(expandedRect.size, maximum: floatingMaximum(screen: screen))
        if fitted != expandedRect.size { floatingSize = fitted; applyViewport(size: fitted) }
        edgeResize = EdgeResize(edges: edges, mouse: mouse, rect: screenRect(expandedRect),
                                maximum: floatingMaximum(screen: screen), screen: screen.visibleFrame)
        logger.info("Floating edge resize began")
        diagnostics.record(.edgeResizeBegan, state: diagnosticState())
    }

    func moveEdgeResize(to mouse: NSPoint) {
        guard let session = edgeResize else { return }
        let rect = FloatingPanelLayout.resized(session.rect, edges: session.edges,
            delta: NSPoint(x: mouse.x - session.mouse.x, y: mouse.y - session.mouse.y),
            maximum: session.maximum, screen: session.screen)
        floatingSize = rect.size
        let local = viewportFrame(size: rect.size)
        panel.setFrameOrigin(NSPoint(x: rect.minX - local.minX, y: rect.minY - local.minY))
        applyViewport(size: rect.size)
    }

    func endEdgeResize(at mouse: NSPoint) {
        moveEdgeResize(to: mouse)
        guard edgeResize != nil else { return }
        edgeResize = nil
        logger.info("Floating size: \(self.expandedRect.width, privacy: .public) x \(self.expandedRect.height, privacy: .public)")
        diagnostics.record(.edgeResizeEnded, state: diagnosticState())
    }

    // MARK: - 悬停 / 点击

    private func handleHover(_ event: NSEvent? = nil) {
        guard !showingSyncSettings, !dragInteraction.preventsCollapse else { return }
        // Shrinking can move the edge past a stationary pointer. Wait for the
        // gesture/animation to finish before accepting a new hover-exit movement.
        guard !pinch.isActive, resizeTimer == nil else { return }
        let loc = screenPoint(for: event)
        switch mode {
        case .expanded:
            let inExpanded = screenRect(rect(for: .expanded)).insetBy(dx: -10, dy: -8).contains(loc)
            if inExpanded {
                pendingCollapse?.cancel()
                pendingCollapse = nil
            } else if pendingCollapse == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingCollapse = nil
                    if self.mode == .expanded, !self.dragInteraction.preventsCollapse,
                       !self.screenRect(self.rect(for: .expanded)).insetBy(dx: -6, dy: -4).contains(NSEvent.mouseLocation) {
                        self.collapse()
                    }
                }
                pendingCollapse = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            }
        case .rest:
            // 悬浮岛体区域 → 立刻弹出
            if screenRect(restRect).insetBy(dx: -14, dy: -10).contains(loc) {
                expand()
            }
        case .hover:
            if !(screenRect(hoverRect).insetBy(dx: -10, dy: -8).contains(loc)
                || screenRect(expandedRect).insetBy(dx: -6, dy: -4).contains(loc)) {
                goTo(.rest)
            }
        }
    }

    private func handleClick(_ e: NSEvent?) {
        guard !dragInteraction.preventsCollapse else { return }
        let loc = screenPoint(for: e)
        switch mode {
        case .expanded:
            if !screenRect(rect(for: .expanded)).insetBy(dx: -8, dy: -8).contains(loc) {
                collapse()
            }
        case .rest, .hover:
            if screenRect(rect(for: mode)).insetBy(dx: -8, dy: -8).contains(loc) {
                expand()
            }
        }
    }

    private func handleRightClick(_ e: NSEvent?) {
        let loc = screenPoint(for: e)
        let inIsland = screenRect(rect(for: mode)).insetBy(dx: -12, dy: -12).contains(loc)
            || screenRect(restRect).insetBy(dx: -12, dy: -12).contains(loc)
        guard inIsland else { return }

        let menu = NSMenu()
        let diagnosticsItem = NSMenuItem(title: "开发者诊断（本机）", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu()
        diagnosticsMenu.autoenablesItems = false
        let toggle = NSMenuItem(title: "自动收集交互诊断", action: #selector(toggleDiagnostics), keyEquivalent: "")
        toggle.state = diagnostics.isEnabled ? .on : .off
        toggle.target = self
        diagnosticsMenu.addItem(toggle)
        let mark = NSMenuItem(title: "记录刚才的交互异常", action: #selector(markInteractionProblem), keyEquivalent: "")
        mark.target = self
        mark.isEnabled = diagnostics.isEnabled
        diagnosticsMenu.addItem(mark)
        let report = NSMenuItem(title: "查看诊断报告…", action: #selector(showDiagnostics), keyEquivalent: "")
        report.target = self
        diagnosticsMenu.addItem(report)
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)
        menu.addItem(.separator())
        #if !ISLAND_TESTFLIGHT
        let syncItem = NSMenuItem(title: "Flomo Sync…", action: #selector(showSyncSettings), keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)
        #endif
        if mode == .expanded {
            let collapseItem = NSMenuItem(title: "Collapse", action: #selector(collapseAction), keyEquivalent: "")
            collapseItem.target = self
            menu.addItem(collapseItem)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit Island Note", action: #selector(quitAction), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: e ?? NSEvent(), for: island)
    }

    @objc private func collapseAction() { collapse() }
    private func diagnosticState() -> InteractionDiagnosticState {
        let screen = (panel.screen ?? notchScreen()).visibleFrame
        return InteractionDiagnosticState(mode: String(describing: mode), floating: dragInteraction.isFloating,
            dragging: dragInteraction.isDragging, docking: dragInteraction.isDocking, edgeResizing: edgeResize != nil,
            animating: resizeTimer != nil, panelKey: panel.isKeyWindow, appActive: NSApp.isActive,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            width: expandedRect.width, height: expandedRect.height,
            targetWidth: targetViewportSize.map { Double($0.width) }, targetHeight: targetViewportSize.map { Double($0.height) },
            screenWidth: screen.width, screenHeight: screen.height)
    }

    @objc func toggleDiagnostics() {
        diagnostics.setEnabled(!diagnostics.isEnabled, state: diagnosticState())
    }

    @objc func markInteractionProblem() {
        diagnostics.markProblem(state: diagnosticState())
        showDiagnostics()
    }

    @objc func showDiagnostics() {
        diagnostics.reloadHistoryIfEmpty()
        diagnostics.flush()
        pendingCollapse?.cancel(); pendingCollapse = nil
        showingSyncSettings = true
        defer { showingSyncSettings = false }
        let alert = NSAlert()
        alert.messageText = "本机交互诊断"
        let findings = diagnostics.recentFindings
        alert.informativeText = "\(diagnostics.isEnabled ? "正在收集" : "已关闭收集")。只记录面板尺寸、手势阶段和交互状态，不记录笔记正文或截图，也不上传。关闭后保留已有记录。\n\n\(findings.isEmpty ? "尚无交互记录。开启后重现问题即可自动记录。" : findings)"
        alert.addButton(withTitle: "完成")
        let open = alert.addButton(withTitle: "打开报告目录")
        open.isEnabled = diagnostics.reportURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let url = diagnostics.reportURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - 状态机

    func expand() {
        guard mode != .expanded else { return }
        do {
            if let updatedText = try store.refreshIfClean() {
                editor.string = updatedText
                editor.setEditingEnabled(true)
            }
        } catch {
            editor.showSaveError("Could not read \(store.path): \(error.localizedDescription)")
        }
        goTo(.expanded)
        #if !ISLAND_TESTFLIGHT
        sync?.request()
        #endif
        Haptics.expand()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            self?.editor.focus()
        }
    }

    func collapse() {
        if dragInteraction.preventsCollapse {
            dragInteraction.cancelAndDock(collapse: true)
            return
        }
        guard mode == .expanded else {
            if mode == .hover { goTo(.rest) }
            return
        }
        guard !finishingCollapse else { return }
        finishingCollapse = true
        // The Markdown editor delivers the new source text asynchronously.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishingCollapse = false
            guard self.mode == .expanded, !self.dragInteraction.preventsCollapse else { return }
            self.editor.flushPending()
            guard self.store.flushSync() else { return }
            self.goTo(.rest)
            Haptics.collapse()
            self.pendingCollapse?.cancel()
            self.pendingCollapse = nil
        }
    }

    func flushEditor() {
        editor.flushPending()
        diagnostics.flush()
    }

    #if !ISLAND_TESTFLIGHT
    private func setupSync() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true).appendingPathComponent("IslandNote")
            let sync = try FlomoSync(stateURL: directory.appendingPathComponent("flomo-sync.json"))
            self.sync = sync
            sync.onStatus = { [weak self] phase, detail in self?.editor.showSyncStatus(phase, detail: detail) }
            sync.readLocal = { [weak self] in
                guard let self else { throw SyncFailure.localUnavailable }
                guard !self.editor.hasMarkedText else { throw SyncFailure.localChanged }
                self.editor.flushPending()
                guard self.store.flushSync() else { throw SyncFailure.localUnavailable }
                if let updated = try self.store.refreshIfClean() { self.editor.replaceFromSync(updated) }
                return self.editor.string
            }
            sync.applyRemote = { [weak self, weak sync] expected, replacement in
                guard let self, let sync else { throw SyncFailure.localUnavailable }
                self.editor.flushPending()
                guard self.editor.string == expected, self.store.flushSync() else { throw SyncFailure.localChanged }
                try sync.backup(expected, name: "island-note-before-pull")
                try self.store.applySyncedText(replacement, expected: expected)
                self.editor.replaceFromSync(replacement)
            }
            store.onSyncNeeded = { [weak sync] in sync?.localChanged() }
            if let token = try FlomoCredential.load() { sync.start(client: FlomoClient(token: token)) }
        } catch {
            editor.showSyncStatus(.failed, detail: "Flomo setup unavailable: \(error.localizedDescription)")
        }
    }

    @objc func showSyncSettings() {
        guard let sync else { FlomoSettings.error("Sync settings could not be loaded. Your local note is still available."); return }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        showingSyncSettings = true
        defer { showingSyncSettings = false }
        editor.flushPending()
        guard store.flushSync() else { return }
        FlomoSettings.show(sync)
    }

    #endif

    /// 只动画遮罩形状（顶边恒定）。expanded 用弹簧回弹。
    private func goTo(_ m: Mode) {
        guard m != mode else { return }
        stopViewportAnimation()
        edgeResize = nil
        resizeHandles.isEnabled = false
        if m != .expanded { expandedRect = expandedFrame(for: panelSize) }
        pinch.reset()
        pendingPinchSize = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
        mode = m
        hitGate.hitRect = rect(for: m)
        island.hitRect = rect(for: m)
        resizeHandles.panelRect = expandedRect

        // 只在展开态显示编辑器，收起时岛体是纯黑胶囊
        let showEditor = (m == .expanded)
        island.setAccessibilityElement(!showEditor)
        island.setAccessibilityRole(showEditor ? .group : .button)
        if showEditor {
            editor.frame = expandedRect
            editor.isHidden = false
            editor.alphaValue = 1
        } else {
            editor.blur()
            editor.alphaValue = 0
            editor.isHidden = true
        }

        let (tR, bR) = radii(for: m)
        let path = m == .expanded ? dragInteraction.path(for: expandedRect)
            : notchPath(rect(for: m), topR: tR, botR: bR)
        let from = maskLayer.presentation()?.path ?? maskLayer.path

        let anim = shapeSpring(for: m)
        anim.fromValue = from
        anim.toValue = path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path
        maskLayer.add(anim, forKey: "path")
        shadowLayer.shadowOpacity = 0
        CATransaction.commit()
    }

    private func shapeSpring(for m: Mode) -> CASpringAnimation {
        // Reuse the existing gentle opening/closing spring for size changes.
        let softEase = CAMediaTimingFunction(controlPoints: 0.25, 0.0, 0.35, 1.0)
        let anim: CASpringAnimation
        if m == .hover {
            let s = CASpringAnimation(keyPath: "path")
            s.mass = 1
            s.stiffness = 140
            s.damping = 22
            s.initialVelocity = 0
            s.duration = max(s.settlingDuration, 0.28)
            s.timingFunction = softEase
            anim = s
        } else {
            // 展开 / 收起：ζ≈0.88，几乎不过冲，尾部轻轻一「让」
            let s = CASpringAnimation(keyPath: "path")
            s.mass = 1
            s.stiffness = 130
            s.damping = 20
            s.initialVelocity = 0
            s.duration = max(s.settlingDuration, 0.58)
            s.timingFunction = softEase
            anim = s
        }
        return anim
    }
}

// MARK: - Editor edge fade

/// 文字区四边羽化；顶部只在内容滚出视口后渐显。
final class EdgeFeatherView: NSView {
    override var isOpaque: Bool { false }
    var topFadeProgress: CGFloat = 0 {
        didSet {
            if abs(topFadeProgress - oldValue) > 0.01 { needsDisplay = true }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        guard b.width > 1, b.height > 1 else { return }
        let clear = NSColor.black.withAlphaComponent(0)
        let topFadeH = min(32, b.height * 0.4)
        let bottomFadeH = min(64, b.height * 0.4)
        let sideW = min(44, b.width * 0.18)

        // 视口顶边要完全遮住被裁切的文字；缩短渐变范围来减轻遮挡。
        if topFadeProgress > 0 {
            let topRect = NSRect(x: 0, y: b.maxY - topFadeH, width: b.width, height: topFadeH)
            NSGradient(colors: [clear, NSColor.black.withAlphaComponent(topFadeProgress)])!
                .draw(in: topRect, angle: 90)
        }

        let botRect = NSRect(x: 0, y: 0, width: b.width, height: bottomFadeH)
        NSGradient(colors: [clear, NSColor.black])!.draw(in: botRect, angle: 270)

        let leftRect = NSRect(x: 0, y: 0, width: sideW, height: b.height)
        NSGradient(colors: [NSColor.black, clear])!.draw(in: leftRect, angle: 0)

        let rightRect = NSRect(x: b.maxX - sideW, y: 0, width: sideW, height: b.height)
        NSGradient(colors: [NSColor.black, clear])!.draw(in: rightRect, angle: 180)
    }
}
