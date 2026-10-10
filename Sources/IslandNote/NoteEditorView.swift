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
    @Published var documentID = UUID().uuidString
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
        let identity = model.documentID
        return NativeTextViewWrapper(
            text: Binding(
                get: { model.text },
                set: { newText in
                    guard model.documentID == identity else { return }
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
            documentId: identity,
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
        .id(identity)
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
    private var localSaveState = LocalSaveState.loading
    private var checkingExpansionWork: DispatchWorkItem?
    private var checkingExpanded = false
    private var motionObservation: NSObjectProtocol?
    private var compositionObservations: [NSObjectProtocol] = []
    private var isComposing = false
    private var statusHoverWork: DispatchWorkItem?
    private var isStatusHovered = false
    private var showsHoverStatus = false
    private let syncButton = StatusIndicatorButton(title: "", target: nil, action: nil)
    private let syncLabel = CATextLayer()
    private var syncButtonWidth: NSLayoutConstraint!
    let outlineModel = HeadingOutlineModel()
    private var outlineRefresh: DispatchWorkItem?
    private var geometryRefresh: DispatchWorkItem?
    private var indexedSource = ""
    private var headingPositions: [(id: Int, y: CGFloat)] = []
    private var lastLayoutWidth: CGFloat = 0
    private var navigationTimer: Timer?
    private var scrollMonitor: Any?
    private let logger = Logger(subsystem: "local.projects.island-note", category: "Outline")

    var motionIsReduced: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var onTextChanged: ((String) -> Void)?
    var onRequestCollapse: (() -> Void)?
    var onRequestQuit: (() -> Void)?
    var onRequestSync: (() -> Void)?
    var onRequestSettings: (() -> Void)?
    var onStatusWidthChanged: ((CGFloat) -> Void)?

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

    /// A new native editor owns its undo stack; queued bindings from the old
    /// document are rejected so they cannot save into the newly selected file.
    func openDocument(_ text: String) {
        model.documentID = UUID().uuidString
        isComposing = false
        string = text
        showLocalSaveState(.saved)
        showSyncStatus(.disconnected, detail: L10n.tr("Flomo not connected"))
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
        syncButton.layer?.cornerRadius = 12
        syncButton.layer?.masksToBounds = true
        syncLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        syncLabel.fontSize = 12
        syncLabel.truncationMode = .end
        syncLabel.foregroundColor = NSColor(white: 0.86, alpha: 1).cgColor
        syncLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        syncLabel.opacity = 0
        syncButton.layer?.addSublayer(syncLabel)

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

        syncButtonWidth = syncButton.widthAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
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
            syncButtonWidth,
            syncButton.heightAnchor.constraint(equalToConstant: 24),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            dragHandle.trailingAnchor.constraint(equalTo: syncButton.leadingAnchor, constant: -8),
            dragHandle.centerYAnchor.constraint(equalTo: syncButton.centerYAnchor),
            dragHandle.heightAnchor.constraint(equalTo: syncButton.heightAnchor),
        ])
        motionObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshStatusIndicator() }
        // The engine intentionally defers its binding while an IME owns marked
        // text. Observe that stage without replacing its native text delegate.
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            compositionObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, let textView = notification.object as? NSTextView,
                      textView.isDescendant(of: self.hostingView) else { return }
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView, textView.isDescendant(of: self.hostingView) else { return }
                    let composing = textView.hasMarkedText()
                    guard composing != self.isComposing else { return }
                    self.isComposing = composing
                    if composing && self.displayedSyncPhase == .synced { self.displayedSyncPhase = .waiting }
                    self.refreshStatusIndicator()
                }
            })
        }
        refreshStatusIndicator()
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            scheduleHeadingGeometry()
            DispatchQueue.main.async { [weak self] in self?.refreshStatusIndicator() }
        }
    }

    func showSyncStatus(_ phase: SyncPhase, detail: String) {
        let wasBusy = displayedSyncPhase.isBusy && checkingExpanded
        checkingExpansionWork?.cancel()
        checkingExpansionWork = nil
        displayedSyncPhase = phase
        syncDetail = detail
        checkingExpanded = phase == .syncing || (phase == .checking && wasBusy)
        if phase == .checking && !checkingExpanded {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.displayedSyncPhase == .checking else { return }
                self.checkingExpanded = true
                self.refreshStatusIndicator()
            }
            checkingExpansionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
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

    @objc private func openSettings() { clearStatusHover(); onRequestSettings?() }

    private func refreshStatusIndicator() {
        let phase = displayedSyncPhase
        let currentLocalState: LocalSaveState = isComposing && localSaveError == nil ? .saving : localSaveState
        let presentation = StatusPresentation(local: currentLocalState, phase: phase, flomoEnabled: isFlomoEnabled,
                                              hovered: showsHoverStatus, checkingExpanded: checkingExpanded)
        let localDetail: String
        switch currentLocalState {
        case .loading: localDetail = L10n.tr("Loading note…")
        case .saving: localDetail = L10n.tr("Saving locally…")
        case .saved: localDetail = L10n.tr("Your note is saved on this Mac.")
        case .failed(let message): localDetail = L10n.tr("Local save failed: ") + message
        }
        let details = isFlomoEnabled ? localDetail + "\n" + phase.title + "\n" + syncDetail : localDetail
        syncButton.setAccessibilityLabel(localSaveError != nil ? L10n.tr("Local save failed") : presentation.summary)
        let isBusy = presentation.tone == .busy
        updateSyncExpansion(presentation.caption, tone: presentation.tone)
        syncButton.setAccessibilityHelp(details)

        let color: NSColor
        switch presentation.tone {
        case .error: color = .systemRed
        case .warning: color = NSColor(red: 0.94, green: 0.70, blue: 0.38, alpha: 1)
        case .success: color = NSColor(red: 0.55, green: 0.80, blue: 0.67, alpha: 1)
        case .busy: color = NSColor(white: 0.68, alpha: 1)
        case .neutral: color = NSColor(white: 0.40, alpha: 1)
        }
        let previousColor = statusDot.presentation()?.backgroundColor ?? statusDot.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusDot.backgroundColor = color.cgColor
        CATransaction.commit()
        let reduceMotion = motionIsReduced()
        if (!isBusy || localSaveError != nil || reduceMotion), statusDot.animation(forKey: "sync-busy") != nil {
            let opacity = statusDot.presentation()?.opacity ?? statusDot.opacity
            statusDot.removeAnimation(forKey: "sync-busy")
            let settle = CABasicAnimation(keyPath: "opacity")
            settle.fromValue = opacity
            settle.toValue = Float(1)
            settle.duration = reduceMotion ? 0.08 : 0.16
            settle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            statusDot.add(settle, forKey: "status-opacity")
        }
        if !reduceMotion {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = previousColor
            fade.toValue = color.cgColor
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            statusDot.add(fade, forKey: "status-color")
            if isBusy, localSaveError == nil, statusDot.animation(forKey: "sync-busy") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = statusDot.presentation()?.opacity ?? statusDot.opacity
                pulse.toValue = Float(0.4)
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                statusDot.removeAnimation(forKey: "status-opacity")
                statusDot.add(pulse, forKey: "sync-busy")
            }
        }
    }

    /// Keep the right edge anchored; the dot leads the text as the control opens.
    private func updateSyncExpansion(_ text: String?, tone: StatusPresentation.Tone) {
        guard let syncButtonWidth, let buttonLayer = syncButton.layer else { return }
        let expanded = text != nil
        let visibleText = text ?? (syncLabel.string as? String ?? "")
        // 12 pt before the dot, 4 pt between dot and text, 11 pt after text.
        let measuredTextWidth = ceil((visibleText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width)
        let textWidth = min(measuredTextWidth, max(0, bounds.width - 71 - 33))
        let width: CGFloat = expanded ? textWidth + 33 : 24
        let changesGeometry = syncButtonWidth.constant != width
        let previousBounds = buttonLayer.presentation()?.bounds ?? buttonLayer.bounds
        let previousPosition = buttonLayer.presentation()?.position ?? buttonLayer.position
        let previousDotPosition = statusDot.presentation()?.position ?? statusDot.position
        let changesText = text != nil && syncLabel.string as? String != visibleText
        if changesText {
            // Leave the currently visible text fading on its own layer. Rapid
            // changes can overlap without an old completion hiding a new label.
            let opacity = syncLabel.presentation()?.opacity ?? syncLabel.opacity
            if opacity > 0 {
                let outgoing = CATextLayer()
                outgoing.font = syncLabel.font
                outgoing.fontSize = syncLabel.fontSize
                outgoing.truncationMode = syncLabel.truncationMode
                outgoing.contentsScale = syncLabel.contentsScale
                outgoing.string = syncLabel.string
                outgoing.frame = syncLabel.frame
                outgoing.foregroundColor = syncLabel.presentation()?.foregroundColor ?? syncLabel.foregroundColor
                outgoing.opacity = opacity
                buttonLayer.insertSublayer(outgoing, below: syncLabel)
                SettingsPalette.animate(outgoing, key: "opacity", value: Float(0), duration: 0.16)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { outgoing.removeFromSuperlayer() }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if changesText {
            syncLabel.removeAnimation(forKey: "opacity")
            syncLabel.opacity = 0
        }
        syncLabel.string = visibleText
        syncLabel.frame = CGRect(x: 22, y: 4, width: textWidth, height: 16)
        syncButtonWidth.constant = width
        layoutSubtreeIfNeeded()
        statusDot.position = CGPoint(x: expanded ? 15 : 12, y: 12)
        CATransaction.commit()
        if changesGeometry {
            let duration = motionIsReduced() ? 0.08 : 0.24
            for (layer, key, from) in [(buttonLayer, "bounds", NSValue(rect: previousBounds)),
                                       (buttonLayer, "position", NSValue(point: previousPosition)),
                                       (statusDot, "position", NSValue(point: previousDotPosition))] {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = from
                animation.toValue = layer.value(forKeyPath: key)
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: "sync-expansion-" + key)
            }
            onStatusWidthChanged?(width)
        }
        if changesText {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = Float(0)
            fade.toValue = Float(1)
            fade.duration = motionIsReduced() ? 0.08 : 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            syncLabel.opacity = 1
            CATransaction.commit()
            syncLabel.add(fade, forKey: "opacity")
        } else {
            SettingsPalette.animate(syncLabel, key: "opacity", value: expanded ? Float(1) : Float(0), duration: 0.16)
        }
        let amber = NSColor(red: 0.94, green: 0.70, blue: 0.38, alpha: 1)
        let tint: NSColor
        switch tone {
        case .error: tint = .systemRed
        case .warning: tint = amber
        case .success: tint = NSColor(red: 0.55, green: 0.80, blue: 0.67, alpha: 1)
        default: tint = NSColor(white: 0.86, alpha: 1)
        }
        SettingsPalette.animate(syncLabel, key: "foregroundColor", value: tint.cgColor, duration: 0.24)
        let background = expanded && (tone == .warning || tone == .error) ? tint.withAlphaComponent(0.12) : NSColor(white: 1, alpha: expanded ? 0.07 : 0)
        SettingsPalette.animate(buttonLayer, key: "backgroundColor", value: background.cgColor, duration: 0.24)
    }

    private func setStatusHovered(_ hovered: Bool) {
        isStatusHovered = hovered
        statusHoverWork?.cancel()
        if hovered {
            guard !isHiddenOrHasHiddenAncestor else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isStatusHovered, !self.isHiddenOrHasHiddenAncestor else { return }
                self.showsHoverStatus = true
                self.refreshStatusIndicator()
            }
            statusHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            showsHoverStatus = false
            refreshStatusIndicator()
        }
    }

    private func clearStatusHover() {
        statusHoverWork?.cancel()
        isStatusHovered = false
        showsHoverStatus = false
        refreshStatusIndicator()
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
        statusHoverWork?.cancel()
        checkingExpansionWork?.cancel()
        if let motionObservation { NSWorkspace.shared.notificationCenter.removeObserver(motionObservation) }
        for observation in compositionObservations { NotificationCenter.default.removeObserver(observation) }
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
        clearStatusHover()
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

    func showLocalSaveState(_ state: LocalSaveState) {
        // A new edit must not erase a previous failed write until a durable save
        // succeeds. Sync warnings remain independently visible after that save.
        if state == .saving, localSaveError != nil { return }
        localSaveState = state
        if state == .saving && displayedSyncPhase == .synced { displayedSyncPhase = .waiting }
        if case .failed(let message) = state { localSaveError = message }
        else { localSaveError = nil }
        refreshStatusIndicator()
    }

    func flashSavedIndicator() { showLocalSaveState(.saved) }

    func showSaveError(_ message: String) { showLocalSaveState(.failed(message)) }

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
        clearStatusHover()
        if let localSaveError {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Local save failed")
            alert.informativeText = localSaveError
            alert.runModal()
        } else {
            if isFlomoEnabled { onRequestSync?() }
            else { onRequestSettings?() }
        }
    }
}
