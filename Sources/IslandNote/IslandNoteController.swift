import AppKit

/// 命中放行：只在当前可见形状内接管点击，其余穿透到下方（菜单栏照常可点）。
final class IslandView: NSView {
    override var isFlipped: Bool { false } // 原点左下，顶 = maxY
    var hitRect = NSRect.zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !hitRect.isEmpty && !hitRect.contains(point) { return nil }
        return super.hitTest(point)
    }
}

/// 无边框、可成为 key 的岛体面板（同 Spirit / DynamicNotchKit 窗口配方）。
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
        case "q":
            NSApp.terminate(nil)
            return true
        default:
            return true
        }
    }
}

/// 固定岛体 + 只动画遮罩形状（借鉴 Spirit NotchApp）。
/// 所有形态顶边钉在屏幕最顶 → 展开/收回不裂缝。
final class IslandNoteController: NSObject {
    private let store: NoteStore

    // 窗口与岛体
    private var panel: IslandPanel!
    private var island: IslandView!
    private var maskLayer: CAShapeLayer!
    private var editor: NoteEditorView!
    private var hitGate: IslandView!

    // 几何
    private var screenFrame = NSRect.zero
    private var notchW: CGFloat = 200
    private var notchH: CGFloat = 32
    private var eW: CGFloat = 460
    private var panelH: CGFloat = 240
    private var gutter: CGFloat = 16
    private var eH: CGFloat = 256

    private var restRect = NSRect.zero
    private var hoverRect = NSRect.zero
    private var expandedRect = NSRect.zero

    private let compactTopR: CGFloat = 10
    private let compactBotR: CGFloat = 20
    private let expandedTopR: CGFloat = 10
    private let expandedBotR: CGFloat = 32

    enum Mode { case rest, hover, expanded }
    private(set) var mode: Mode = .rest

    private var pendingCollapse: DispatchWorkItem?
    private var finishingCollapse = false
    private var monitors: [Any] = []

    init(store: NoteStore) {
        self.store = store
        super.init()
        installMainMenu()
        setup()
        bindStore()
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
        let L = r.minX, R = r.maxX, T = r.maxY, B = r.minY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: L, y: T))
        p.addQuadCurve(to: CGPoint(x: L + topR, y: T - topR), control: CGPoint(x: L + topR, y: T))
        p.addLine(to: CGPoint(x: L + topR, y: B + botR))
        p.addQuadCurve(to: CGPoint(x: L + topR + botR, y: B), control: CGPoint(x: L + topR, y: B))
        p.addLine(to: CGPoint(x: R - topR - botR, y: B))
        p.addQuadCurve(to: CGPoint(x: R - topR, y: B + botR), control: CGPoint(x: R - topR, y: B))
        p.addLine(to: CGPoint(x: R - topR, y: T - topR))
        p.addQuadCurve(to: CGPoint(x: R, y: T), control: CGPoint(x: R - topR, y: T))
        p.closeSubpath()
        return p
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
        panelH = 275
        gutter = 16
        eW = 460
        eH = panelH + gutter

        let winFrame = NSRect(x: sf.midX - eW / 2, y: sf.maxY - eH, width: eW, height: eH)

        // 可见形状——顶边都 = eH（屏幕最顶），只向下生长
        expandedRect = NSRect(x: 0, y: eH - panelH, width: eW, height: panelH)
        let restW = max(notchW * 1.06, 210) - 11
        restRect = NSRect(x: (eW - restW) / 2, y: eH - barH, width: restW, height: barH)
        hoverRect = NSRect(
            x: (eW - restW - 14) / 2,
            y: eH - barH - 4,
            width: restW + 14,
            height: barH + 4
        )

        panel = IslandPanel(
            contentRect: winFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

        island = IslandView(frame: NSRect(origin: .zero, size: winFrame.size))
        island.wantsLayer = true
        island.autoresizesSubviews = true
        island.layer?.backgroundColor = NSColor.black.cgColor
        maskLayer = CAShapeLayer()
        maskLayer.frame = island.bounds
        maskLayer.path = notchPath(restRect, topR: compactTopR, botR: compactBotR)
        island.layer?.mask = maskLayer

        editor = NoteEditorView(frame: expandedRect)
        editor.autoresizingMask = [.width, .height]
        editor.onTextChanged = { [weak self] text in
            self?.store.save(text)
        }
        editor.onRequestCollapse = { [weak self] in
            self?.collapse()
        }
        editor.onRequestQuit = {
            NSApp.terminate(nil)
        }
        // 编辑器只覆盖可见形状（expandedRect）：底边 = 遮罩底边，
        // 原先铺满全窗口时底部 16px gutter 成了「滚得到但永远看不见」的死区。
        editor.frame = expandedRect
        editor.isHidden = true
        editor.alphaValue = 0
        island.addSubview(editor)

        content.addSubview(island)
        panel.contentView = content
        panel.orderFrontRegardless()

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

    private func installMonitors() {
        let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.handleHover()
        }
        let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] e in
            self?.handleHover()
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
            guard let self else { return e }
            return self.editor.handleKey(e) ?? e
        }
        monitors = [g, l, gc, lc, gr, lr, lk].compactMap { $0 }
    }

    // MARK: - 悬停 / 点击

    private func handleHover() {
        let loc = NSEvent.mouseLocation
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
                    if self.mode == .expanded,
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
        let loc = NSEvent.mouseLocation
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
        let loc = NSEvent.mouseLocation
        let inIsland = screenRect(rect(for: mode)).insetBy(dx: -12, dy: -12).contains(loc)
            || screenRect(restRect).insetBy(dx: -12, dy: -12).contains(loc)
        guard inIsland else { return }

        let menu = NSMenu()
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
        Haptics.expand()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            self?.editor.focus()
        }
    }

    func collapse() {
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
            guard self.mode == .expanded else { return }
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
    }

    /// 只动画遮罩形状（顶边恒定）。expanded 用弹簧回弹。
    private func goTo(_ m: Mode) {
        guard m != mode else { return }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        mode = m
        hitGate.hitRect = rect(for: m)

        // 只在展开态显示编辑器，收起时岛体是纯黑胶囊
        let showEditor = (m == .expanded)
        if showEditor {
            editor.isHidden = false
            editor.alphaValue = 1
        } else {
            editor.blur()
            editor.alphaValue = 0
            editor.isHidden = true
        }

        let (tR, bR) = radii(for: m)
        let path = notchPath(rect(for: m), topR: tR, botR: bR)
        let from = maskLayer.presentation()?.path ?? maskLayer.path

        // 方案 A + 轻微缓入缓出（温和 S 曲线，不做成猛拐，避免咯噔）
        let softEase = CAMediaTimingFunction(controlPoints: 0.25, 0.0, 0.35, 1.0)
        let anim: CABasicAnimation
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
        anim.fromValue = from
        anim.toValue = path
        maskLayer.add(anim, forKey: "path")
        maskLayer.path = path
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
        let verticalFadeH = min(64, b.height * 0.4)
        let sideW = min(44, b.width * 0.18)

        // 上下效果对调并反转
        if topFadeProgress > 0 {
            let topRect = NSRect(x: 0, y: b.maxY - verticalFadeH, width: b.width, height: verticalFadeH)
            NSGradient(colors: [clear, NSColor.black.withAlphaComponent(topFadeProgress)])!
                .draw(in: topRect, angle: 90)
        }

        let botRect = NSRect(x: 0, y: 0, width: b.width, height: verticalFadeH)
        NSGradient(colors: [clear, NSColor.black])!.draw(in: botRect, angle: 270)

        let leftRect = NSRect(x: 0, y: 0, width: sideW, height: b.height)
        NSGradient(colors: [NSColor.black, clear])!.draw(in: leftRect, angle: 0)

        let rightRect = NSRect(x: b.maxX - sideW, y: 0, width: sideW, height: b.height)
        NSGradient(colors: [NSColor.black, clear])!.draw(in: rightRect, angle: 180)
    }
}
