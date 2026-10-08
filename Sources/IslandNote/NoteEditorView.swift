import AppKit
import SwiftUI
import MarkdownEngine
import OSLog

extension Notification.Name {
    static let islandNoteBold = Notification.Name("IslandNote.applyBold")
    static let islandNoteItalic = Notification.Name("IslandNote.applyItalic")
}

private final class NoteEditorModel: ObservableObject {
    @Published var localeRevision = 0
    @Published var text = ""
    @Published var isEditable = false
}

private struct MarkdownEditorHost: View {
    @ObservedObject var model: NoteEditorModel
    let onTextChanged: (String) -> Void
    let onBuildContextMenu: (NSMenu, NSRange) -> NSMenu
    let onLimitExceeded: () -> Void

    private static let configuration: MarkdownEditorConfiguration = {
        var config = MarkdownEditorConfiguration.default
        var theme = MarkdownEditorTheme.default
        theme.bodyText = NSColor(white: 0.92, alpha: 1)
        theme.mutedText = NSColor(white: 0.58, alpha: 1)
        theme.disabledText = NSColor(white: 0.42, alpha: 1)
        theme.headingMarker = NSColor(white: 0.48, alpha: 1)
        theme.link = NSColor(red: 0.57, green: 0.76, blue: 1, alpha: 1)
        theme.incompleteLink = theme.link
        theme.strikethroughColor = theme.mutedText
        config.theme = theme
        config.textInsets = TextInsets(horizontal: 36, vertical: 10)
        config.lists.indentPerLevel = 10
        config.safeAreaInsets = SafeAreaInsets(bottom: 64)
        config.spellChecking = SpellCheckingPolicy(
            continuousSpellChecking: false,
            grammarChecking: false,
            automaticSpellingCorrection: false
        )
        config.paragraph = ParagraphStyle(spacingFactor: 0.2, lineHeightExtraSpacing: 3)
        config.services.bus = MarkdownEditorBus(
            applyBoldRequest: .islandNoteBold,
            applyItalicRequest: .islandNoteItalic
        )
        return config
    }()

    var body: some View {
        NativeTextViewWrapper(
            text: Binding(
                get: { model.text },
                set: { newText in
                    if DocumentLimits.count(newText) > DocumentLimits.limit,
                       DocumentLimits.count(newText) >= DocumentLimits.count(model.text) {
                        // Also catches smart-input expansions and edits that bypass
                        // the normal text binding. Keep the engine’s native delegate
                        // intact for Chinese composition and list editing.
                        let retained = model.text
                        model.text = retained
                        onLimitExceeded()
                        return
                    }
                    model.text = newText
                    onTextChanged(newText)
                }
            ),
            configuration: Self.configuration,
            fontSize: 14,
            documentId: "island-note",
            isEditable: model.isEditable,
            onBuildContextMenu: onBuildContextMenu,
            placeholder: NSAttributedString(
                string: L10n.tr("Write something…"),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor(white: 1, alpha: 0.28),
                ]
            )
        )
    }
}

/// Live-rendered Markdown editor inside the existing island panel.
final class NoteEditorView: NSView {
    let dragHandle = PanelDragView(frame: .zero)
    private let model = NoteEditorModel()
    private var hostingView: NSHostingView<MarkdownEditorHost>!
    private weak var featherView: EdgeFeatherView?
    private weak var observedClipView: NSClipView?
    private var scrollObservation: NSObjectProtocol?
    private let statusDot = CALayer()
    private var isFlomoEnabled = false
    private var syncDetail = "Flomo is not connected. Click to set up sync."
    private var displayedSyncPhase = SyncPhase.disconnected
    private var localSaveError: String?
    private var showingSavePulse = false
    private var savedPulse: DispatchWorkItem?
    private let statusHint = StatusHoverView(frame: .zero)
    private var statusHintWork: DispatchWorkItem?
    private var isStatusHovered = false
    private let syncButton = StatusIndicatorButton(title: "", target: nil, action: nil)
    let outlineModel = HeadingOutlineModel()
    private var outlineRefresh: DispatchWorkItem?
    private var geometryRefresh: DispatchWorkItem?
    private var indexedSource = ""
    private var headingPositions: [(id: Int, y: CGFloat)] = []
    private var lastLayoutWidth: CGFloat = 0
    private var navigationTimer: Timer?
    private var scrollMonitor: Any?
    private let logger = Logger(subsystem: "local.projects.island-note", category: "Outline")

    var onTextChanged: ((String) -> Void)?
    var onRequestCollapse: (() -> Void)?
    var onRequestQuit: (() -> Void)?
    var onRequestSync: (() -> Void)?
    var onRequestSettings: (() -> Void)?

    var string: String {
        get { model.text }
        set {
            model.text = newValue
            refreshOutline(newValue)
        }
    }

    func setEditingEnabled(_ enabled: Bool) {
        model.isEditable = enabled
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        wantsLayer = true
        let root = MarkdownEditorHost(
            model: model,
            onTextChanged: { [weak self] text in
                guard let self else { return }
                self.onTextChanged?(text)
                self.outlineRefresh?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refreshOutline(text) }
                self.outlineRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            },
            onBuildContextMenu: { [weak self] menu, _ in
                self?.appendAppMenuItems(to: menu)
                Self.localizeMenu(menu)
                return menu
            },
            onLimitExceeded: { [weak self] in
                if let self { self.hostedTextView(in: self.hostingView)?.undoManager?.removeAllActions() }
                self?.showSaveError(L10n.tr("30,000-character limit. The added text was not saved."))
            }
        )
        hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.appearance = NSAppearance(named: .darkAqua)
        addSubview(hostingView)

        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragHandle)

        syncButton.translatesAutoresizingMaskIntoConstraints = false
        syncButton.isBordered = false
        syncButton.font = .systemFont(ofSize: 11, weight: .medium)
        syncButton.appearance = NSAppearance(named: .darkAqua)
        syncButton.onHover = { [weak self] hovered in self?.setStatusHovered(hovered) }
        syncButton.setAccessibilityLabel(L10n.tr("Local save status"))
        syncButton.wantsLayer = true
        syncButton.target = self
        syncButton.action = #selector(openSyncSettings)
        addSubview(syncButton)
        statusDot.frame = CGRect(x: 9, y: 9, width: 6, height: 6)
        statusDot.cornerRadius = 3
        syncButton.layer?.addSublayer(statusDot)
        refreshStatusIndicator()

        let featherView = EdgeFeatherView(frame: .zero)
        self.featherView = featherView
        featherView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(featherView)

        let outline = HeadingOutlineHost(model: outlineModel)
        outline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outline)
        outlineModel.onNavigate = { [weak self] heading in self?.navigate(to: heading) }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown, .magnify]) { [weak self] event in
            if let self, event.window === self.window { self.stopNavigation() }
            return event
        }

        statusHint.translatesAutoresizingMaskIntoConstraints = false
        statusHint.isHidden = true
        statusHint.alphaValue = 0
        addSubview(statusHint, positioned: .above, relativeTo: nil)
        statusHint.layer?.zPosition = 100

        NSLayoutConstraint.activate([
            statusHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            statusHint.topAnchor.constraint(equalTo: syncButton.bottomAnchor, constant: 3),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            featherView.leadingAnchor.constraint(equalTo: hostingView.leadingAnchor),
            featherView.trailingAnchor.constraint(equalTo: hostingView.trailingAnchor),
            featherView.topAnchor.constraint(equalTo: hostingView.topAnchor),
            featherView.bottomAnchor.constraint(equalTo: hostingView.bottomAnchor),

            outline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            outline.topAnchor.constraint(equalTo: hostingView.topAnchor, constant: 4),
            outline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            outline.widthAnchor.constraint(equalToConstant: 264),

            syncButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            syncButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            syncButton.widthAnchor.constraint(equalToConstant: 24),
            syncButton.heightAnchor.constraint(equalToConstant: 24),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            dragHandle.trailingAnchor.constraint(equalTo: syncButton.leadingAnchor, constant: -8),
            dragHandle.centerYAnchor.constraint(equalTo: syncButton.centerYAnchor),
            dragHandle.heightAnchor.constraint(equalTo: syncButton.heightAnchor),
        ])
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            scheduleHeadingGeometry()
        }
    }

    func showSyncStatus(_ phase: SyncPhase, detail: String) {
        displayedSyncPhase = phase
        syncDetail = detail
        refreshStatusIndicator()
    }


    func setFlomoEnabled(_ enabled: Bool) {
        isFlomoEnabled = enabled
        refreshStatusIndicator()
    }

    func refreshLocalizedUI() {
        model.localeRevision += 1
        outlineModel.objectWillChange.send()
        dragHandle.refreshLocalizedUI()
        refreshStatusIndicator()
    }

    @objc private func openSettings() { hideStatusHint(); onRequestSettings?() }

    private func refreshStatusIndicator() {
        let phase = displayedSyncPhase
        let localDetail = localSaveError.map { L10n.tr("Local save failed: ") + $0 }
            ?? (showingSavePulse ? L10n.tr("Saved locally just now.") : L10n.tr("Your note is saved on this Mac."))
        let details = isFlomoEnabled ? localDetail + "\n" + phase.title + "\n" + syncDetail : localDetail
        statusHint.label.stringValue = localSaveError != nil ? L10n.tr("Not saved · Click for details")
            : (isFlomoEnabled ? phase.hoverSummary : L10n.tr("Saved locally"))
        syncButton.setAccessibilityLabel(localSaveError != nil ? L10n.tr("Local save failed")
            : (isFlomoEnabled ? phase.title : L10n.tr("Local save status")))
        let needsAction = isFlomoEnabled && phase.needsAction
        let isBusy = isFlomoEnabled && phase.isBusy
        syncButton.setAccessibilityHelp(details)

        // A local write failure must remain visible even if Flomo reports success.
        // A successful local save must not hide a sync conflict or connection error.
        let color: NSColor
        if localSaveError != nil { color = .systemRed }
        else if needsAction { color = NSColor(red: 0.94, green: 0.70, blue: 0.38, alpha: 1) }
        else if showingSavePulse { color = NSColor(red: 0.55, green: 0.80, blue: 0.67, alpha: 1) }
        else { color = NSColor(white: isBusy ? 0.68 : 0.40, alpha: 1) }
        let previousColor = statusDot.presentation()?.backgroundColor ?? statusDot.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusDot.backgroundColor = color.cgColor
        CATransaction.commit()
        statusDot.removeAnimation(forKey: "sync-busy")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = previousColor
            fade.toValue = color.cgColor
            fade.duration = 0.18
            statusDot.add(fade, forKey: "status-color")
            if isBusy, !showingSavePulse, localSaveError == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.4
                pulse.toValue = 1
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                statusDot.add(pulse, forKey: "sync-busy")
            }
        }
    }

    private func setStatusHovered(_ hovered: Bool) {
        isStatusHovered = hovered
        statusHintWork?.cancel()
        if hovered {
            guard !isHiddenOrHasHiddenAncestor else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isStatusHovered else { return }
                self.statusHint.isHidden = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                    self.statusHint.animator().alphaValue = 1
                }
            }
            statusHintWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                statusHint.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, !self.isStatusHovered else { return }
                self.statusHint.isHidden = true
            }
        }
    }

    private func hideStatusHint() {
        statusHintWork?.cancel()
        isStatusHovered = false
        statusHint.isHidden = true
        statusHint.alphaValue = 0
    }

    func replaceFromSync(_ text: String) {
        let view = hostedTextView(in: hostingView)
        let selection = view?.selectedRange()
        view?.undoManager?.removeAllActions()
        string = text
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.hostedTextView(in: self.hostingView) else { return }
            view.undoManager?.removeAllActions()
            if let selection { view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0)) }
        }
    }

    private func refreshOutline(_ source: String) {
        guard source != indexedSource else { return }
        stopNavigation()
        indexedSource = source
        outlineModel.headings = DocumentHeading.parse(source)
        headingPositions = []
        scheduleHeadingGeometry()
        logger.debug("Indexed \(self.outlineModel.headings.count) headings")
    }

    private func scheduleHeadingGeometry() {
        geometryRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshHeadingGeometry() }
        geometryRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func refreshHeadingGeometry() {
        guard outlineModel.isVisible, let textView = hostedTextView(in: hostingView),
              textView.string == indexedSource,
              let layout = textView.textLayoutManager,
              let content = layout.textContentManager,
              let documentView = textView.enclosingScrollView?.documentView else { return }
        layout.ensureLayout(for: layout.documentRange)
        headingPositions = outlineModel.headings.compactMap { heading in
            guard let location = content.location(layout.documentRange.location, offsetBy: heading.offset) else { return nil }
            var y: CGFloat?
            layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                y = textView.convert(frame, to: documentView).minY
                return false
            }
            return y.map { (heading.id, $0) }
        }
        updateActiveHeading()
    }

    private func updateActiveHeading() {
        guard let scroll = hostedScrollView(in: hostingView), !headingPositions.isEmpty else { return }
        let clip = scroll.contentView
        let readingY = clip.bounds.minY + scroll.contentInsets.top + 24
        var bottom = clip.bounds
        bottom.origin.y = clip.documentRect.maxY
        let lastOrigin = clip.constrainBoundsRect(bottom).minY
        // A short final section cannot align to the top of a tall viewport.
        let atEnd = lastOrigin > -scroll.contentInsets.top + 1 && clip.bounds.minY >= lastOrigin - 1
        let active = atEnd ? headingPositions.last?.id
            : (headingPositions.last(where: { $0.y <= readingY })?.id ?? headingPositions.first?.id)
        if outlineModel.activeID != active { outlineModel.activeID = active }
    }

    func navigate(to requested: DocumentHeading) {
        guard let textView = hostedTextView(in: hostingView), let scroll = textView.enclosingScrollView else { return }
        // An edit may be newer than the debounced index. Resolve the same title
        // again rather than scrolling to an obsolete source offset.
        outlineRefresh?.cancel()
        refreshOutline(textView.string)
        guard let heading = outlineModel.headings.filter({ $0.title == requested.title })
            .min(by: { abs($0.offset - requested.offset) < abs($1.offset - requested.offset) }) else { return }
        stopNavigation()
        refreshHeadingGeometry()
        guard let position = headingPositions.first(where: { $0.id == heading.id }) else {
            logger.error("Heading navigation could not resolve text layout")
            return
        }
        let clip = scroll.contentView
        let start = clip.bounds.origin
        var proposed = clip.bounds
        proposed.origin.y = position.y - scroll.contentInsets.top - 12
        let target = clip.constrainBoundsRect(proposed).origin
        logger.debug("Navigate to heading at source offset \(heading.offset)")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
            return
        }
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self, weak scroll] _ in
            guard let self, let scroll else { return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.42)
            let eased = 1 - pow(1 - progress, 3)
            scroll.contentView.scroll(to: NSPoint(x: start.x, y: start.y + (target.y - start.y) * eased))
            scroll.reflectScrolledClipView(scroll.contentView)
            if progress >= 1 { self.stopNavigation() }
        }
        navigationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopNavigation() {
        navigationTimer?.invalidate()
        navigationTimer = nil
    }

    private func hostedTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews {
            if let textView = hostedTextView(in: child) { return textView }
        }
        return nil
    }

    private func hostedScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = hostedScrollView(in: child) { return scrollView }
        }
        return nil
    }

    private func observeScrollPosition() {
        guard let scrollView = hostedScrollView(in: hostingView) else { return }
        let clipView = scrollView.contentView
        if observedClipView !== clipView {
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            scrollObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.updateTopFade()
            }
        }
        updateTopFade()
    }

    private func updateTopFade() {
        guard let scrollView = hostedScrollView(in: hostingView) else { return }
        let topY = -scrollView.contentInsets.top
        let scrolled = max(0, scrollView.contentView.bounds.minY - topY)
        featherView?.topFadeProgress = min(1, scrolled / 16)
        updateActiveHeading()
    }

    deinit {
        statusHintWork?.cancel()
        outlineRefresh?.cancel()
        geometryRefresh?.cancel()
        navigationTimer?.invalidate()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
    }

    func focus() {
        hostingView.layoutSubtreeIfNeeded()
        observeScrollPosition()
        scheduleHeadingGeometry()
        if let textView = hostedTextView(in: hostingView) {
            window?.makeFirstResponder(textView)
        }
    }

    func blur() {
        dragHandle.clearHover()
        hideStatusHint()
        stopNavigation()
        outlineModel.hoveredID = nil
        if window?.firstResponder === hostedTextView(in: hostingView) {
            window?.makeFirstResponder(nil)
        }
    }

    var hasMarkedText: Bool { hostedTextView(in: hostingView)?.hasMarkedText() ?? false }

    func flushPending() {
        onTextChanged?(model.text)
    }

    func flashSavedIndicator() {
        savedPulse?.cancel()
        localSaveError = nil
        showingSavePulse = true
        refreshStatusIndicator()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showingSavePulse = false
            self.refreshStatusIndicator()
        }
        savedPulse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func showSaveError(_ message: String) {
        savedPulse?.cancel()
        showingSavePulse = false
        localSaveError = message
        refreshStatusIndicator()
    }

    /// Esc closes the island; undo stays scoped to the editor's document.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            onRequestCollapse?()
            return nil
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            let um = hostedTextView(in: hostingView)?.undoManager
            if event.modifierFlags.contains(.shift) {
                if um?.canRedo == true { um?.redo() }
            } else if um?.canUndo == true {
                um?.undo()
            }
            return nil
        }
        return event
    }

    static func localizeMenu(_ menu: NSMenu) {
        for item in menu.items {
            item.title = L10n.tr(item.title)
            if let submenu = item.submenu { localizeMenu(submenu) }
        }
    }

    private func appendAppMenuItems(to menu: NSMenu) {
            let settings = NSMenuItem(title: L10n.tr("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if isFlomoEnabled {
            let sync = NSMenuItem(title: L10n.tr("Flomo Sync…"), action: #selector(openSyncSettings), keyEquivalent: "")
            sync.target = self
            menu.addItem(sync)
        }
        menu.addItem(.separator())
        let bold = NSMenuItem(title: L10n.tr("Bold"), action: #selector(applyBold), keyEquivalent: "b")
        bold.target = self
        menu.addItem(bold)
        let italic = NSMenuItem(title: L10n.tr("Italic"), action: #selector(applyItalic), keyEquivalent: "i")
        italic.target = self
        menu.addItem(italic)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.tr("Quit Island Note"), action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func applyBold() { NotificationCenter.default.post(name: .islandNoteBold, object: nil) }
    @objc private func applyItalic() { NotificationCenter.default.post(name: .islandNoteItalic, object: nil) }
    @objc private func quitFromMenu() { onRequestQuit?() }
    @objc private func openSyncSettings() {
        hideStatusHint()
        if let localSaveError {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Local save failed")
            alert.informativeText = localSaveError
            alert.runModal()
        } else {
            if isFlomoEnabled, displayedSyncPhase.needsAction { onRequestSync?() }
            else { onRequestSettings?() }
        }
    }
}
