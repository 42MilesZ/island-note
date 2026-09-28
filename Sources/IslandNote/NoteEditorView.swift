import AppKit
import SwiftUI
import MarkdownEngine
import OSLog

extension Notification.Name {
    static let islandNoteBold = Notification.Name("IslandNote.applyBold")
    static let islandNoteItalic = Notification.Name("IslandNote.applyItalic")
}

private final class NoteEditorModel: ObservableObject {
    @Published var text = ""
    @Published var isEditable = false
}

private struct MarkdownEditorHost: View {
    @ObservedObject var model: NoteEditorModel
    let onTextChanged: (String) -> Void
    let onBuildContextMenu: (NSMenu, NSRange) -> NSMenu

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
                string: "写点什么…",
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
    private let model = NoteEditorModel()
    private var hostingView: NSHostingView<MarkdownEditorHost>!
    private weak var featherView: EdgeFeatherView?
    private weak var observedClipView: NSClipView?
    private var scrollObservation: NSObjectProtocol?
    private let savedDot = NSView()
    private var savedPulse: DispatchWorkItem?
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
                return menu
            }
        )
        hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.appearance = NSAppearance(named: .darkAqua)
        addSubview(hostingView)

        savedDot.translatesAutoresizingMaskIntoConstraints = false
        savedDot.wantsLayer = true
        savedDot.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0).cgColor
        savedDot.layer?.cornerRadius = 3
        addSubview(savedDot)

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

            savedDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            savedDot.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            savedDot.widthAnchor.constraint(equalToConstant: 6),
            savedDot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            scheduleHeadingGeometry()
        }
    }

    private func refreshOutline(_ source: String) {
        guard source != indexedSource else { return }
        stopNavigation()
        indexedSource = source
        outlineModel.headings = DocumentHeading.parse(source)
        if !outlineModel.headings.contains(where: { $0.id == outlineModel.hoveredID }) {
            outlineModel.hoveredID = nil
        }
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
        Haptics.outlineNavigate()
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
        stopNavigation()
        outlineModel.hoveredID = nil
        if window?.firstResponder === hostedTextView(in: hostingView) {
            window?.makeFirstResponder(nil)
        }
    }

    func flushPending() {
        onTextChanged?(model.text)
    }

    func flashSavedIndicator() {
        savedPulse?.cancel()
        savedDot.toolTip = nil
        savedDot.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.9).cgColor
        let work = DispatchWorkItem { [weak self] in
            self?.savedDot.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0).cgColor
        }
        savedPulse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func showSaveError(_ message: String) {
        savedPulse?.cancel()
        savedDot.toolTip = message
        savedDot.layer?.backgroundColor = NSColor.systemRed.cgColor
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

    private func appendAppMenuItems(to menu: NSMenu) {
        menu.addItem(.separator())
        let bold = NSMenuItem(title: "Bold", action: #selector(applyBold), keyEquivalent: "b")
        bold.target = self
        menu.addItem(bold)
        let italic = NSMenuItem(title: "Italic", action: #selector(applyItalic), keyEquivalent: "i")
        italic.target = self
        menu.addItem(italic)
        menu.addItem(.separator())
        let collapse = NSMenuItem(title: "Collapse", action: #selector(collapseFromMenu), keyEquivalent: "")
        collapse.target = self
        menu.addItem(collapse)
        let quit = NSMenuItem(title: "Quit Island Note", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func applyBold() { NotificationCenter.default.post(name: .islandNoteBold, object: nil) }
    @objc private func applyItalic() { NotificationCenter.default.post(name: .islandNoteItalic, object: nil) }
    @objc private func collapseFromMenu() { onRequestCollapse?() }
    @objc private func quitFromMenu() { onRequestQuit?() }
}
