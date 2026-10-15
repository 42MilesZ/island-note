import AppKit
import OSLog

enum SyncReviewAction { case choose(SyncChoice), resume }

/// A stable comparison viewport. TextKit 1 lays out each immutable copy once;
/// native scrolling does not rebuild text, constraints or Markdown previews.
@MainActor
final class FlomoConflictWindowController: NSWindowController, NSWindowDelegate {
    private var continuation: CheckedContinuation<SyncReviewAction?, Never>?
    private(set) var localScroll: NSScrollView!
    private(set) var remoteScroll: NSScrollView!
    private(set) var localButton: SettingsButton!
    private(set) var remoteButton: SettingsButton!
    private(set) var mergeButton: SettingsButton!
    private(set) var scrollLockButton: SettingsButton!
    private(set) var isScrollLocked = true
    private var synchronizingScroll = false
    private weak var lastScrolledView: NSScrollView?
    private var scrollBounds: [ObjectIdentifier: NSRect] = [:]
    private var scrollObservations: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "local.projects.island-note", category: "SyncReview")

    convenience init(conflict: SyncConflict, sync: FlomoSync) {
        self.init(conflict: conflict, phase: sync.phase, lastVerifiedAt: sync.record.lastVerifiedAt,
                  canChoose: sync.record.enabled && !sync.isStopped,
                  canMerge: sync.record.enabled && sync.record.pendingWrite == nil && sync.record.pendingMerge == nil,
                  reviewError: sync.reviewError)
    }

    init(conflict: SyncConflict, phase: SyncPhase, lastVerifiedAt: Date?, canChoose: Bool, canMerge: Bool, reviewError: String? = nil) {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(880, available.width - 80),
                                                  height: min(680, available.height - 80)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Review sync differences")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 500)
        super.init(window: window)
        window.delegate = self
        build(conflict: conflict, phase: phase, lastVerifiedAt: lastVerifiedAt, canChoose: canChoose, canMerge: canMerge, reviewError: reviewError)
        observeScrolling()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func run() async -> SyncReviewAction? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            showWindow(nil)
            prepareTextLayout()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Complete layout before the first scroll; no lazy height corrections while
    /// scrolling through a long copy. Resize still uses native text reflow.
    func prepareTextLayout() {
        let start = ProcessInfo.processInfo.systemUptime
        synchronizingScroll = true
        window?.contentView?.layoutSubtreeIfNeeded()
        for scroll in [localScroll!, remoteScroll!] {
            guard let view = scroll.documentView as? NSTextView, let container = view.textContainer else { continue }
            view.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(view.frame.height, scroll.contentSize.height)))
            view.layoutManager?.ensureLayout(for: container)
            view.sizeToFit()
        }
        // Keep a fresh comparison at its beginning while AppKit settles insets.
        if isScrollLocked && lastScrolledView == nil {
            for scroll in [localScroll!, remoteScroll!] {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.documentRect.minY))
                scroll.reflectScrolledClipView(clip)
            }
        }
        // AppKit can coalesce bounds notifications during initial layout.
        for scroll in [localScroll!, remoteScroll!] {
            scrollBounds[ObjectIdentifier(scroll)] = scroll.contentView.bounds
        }
        synchronizingScroll = false
        if isScrollLocked { synchronizeScroll(from: lastScrolledView ?? localScroll) }
        let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
        logger.info("Comparison layout prepared in \(duration, format: .fixed(precision: 2), privacy: .public) ms")
    }

    private func build(conflict: SyncConflict, phase: SyncPhase, lastVerifiedAt: Date?, canChoose: Bool, canMerge: Bool, reviewError: String? = nil) {
        guard let window else { return }
        let root = SettingsSurface(role: .page)
        window.contentView = root
        let header = NSStackView()
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        let title = label("Choose the copy to keep", size: 26)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollLockButton = SettingsButton(title: "", target: self, action: #selector(toggleScrollLock))
        scrollLockButton.setButtonType(.pushOnPushOff)
        scrollLockButton.state = .on
        scrollLockButton.imagePosition = .imageOnly
        scrollLockButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        scrollLockButton.setAccessibilityIdentifier("syncReview.scrollLock")
        scrollLockButton.setAccessibilityLabel(L10n.tr("Synchronized scrolling"))
        scrollLockButton.setAccessibilityRole(.checkBox)
        updateScrollLockAppearance(animated: false)
        let titleRow = NSStackView(views: [title, NSView(), scrollLockButton])
        titleRow.orientation = .horizontal; titleRow.alignment = .centerY; titleRow.spacing = 16
        header.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        let explanation: String
        switch phase {
        case .connectionFailed, .offline, .authorizationRequired:
            explanation = "Could not refresh. These are the last captured copies."
        case .verifyWrite, .formattingChanged:
            explanation = "The last upload could not be confirmed. Compare both copies before continuing."
        case .mergeRequired:
            explanation = "These notes have different text. Choose one, or keep both in the same memo."
        default:
            explanation = "Both copies have changes. Your choice will be synced to both sides."
        }
        header.addArrangedSubview(label(reviewError ?? L10n.tr(explanation), size: 14, secondary: true, wrapping: true, localized: false))
        let verified = lastVerifiedAt.map { L10n.format("Last synced: %@", Self.dateText($0)) } ?? L10n.tr("No verified sync yet")
        header.addArrangedSubview(label(verified + " · " + L10n.format("Compared: %@", Self.dateText(conflict.capturedAt)),
                                       size: 13, secondary: true, wrapping: true, localized: false))

        let columns = NSStackView()
        columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 20; columns.distribution = .fillEqually
        let left = column(title: "Island Note", updated: conflict.localUpdatedAt.map(Self.dateText),
                          text: conflict.local, action: #selector(useLocal), hint: "Updates Flomo", enabled: canChoose)
        let right = column(title: "Flomo", updated: Self.remoteDateText(conflict.remote.updatedAt),
                           text: SyncDocument.fromFlomo(conflict.remote.content), action: #selector(useRemote), hint: "Updates Island Note", enabled: canChoose)
        localScroll = left.scroll; localButton = left.button
        remoteScroll = right.scroll; remoteButton = right.button
        localButton.setAccessibilityIdentifier("syncReview.local")
        remoteButton.setAccessibilityIdentifier("syncReview.remote")
        localButton.setAccessibilityLabel(L10n.tr("Use Island Note for both copies"))
        remoteButton.setAccessibilityLabel(L10n.tr("Use Flomo for both copies"))
        columns.addArrangedSubview(left.view); columns.addArrangedSubview(right.view)

        let footer = NSStackView()
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 12
        let preservation = label(canChoose ? "Originals are backed up before replacement." : "Sync is paused. Resume to apply a choice.",
                                 size: 13, secondary: true, wrapping: true)
        preservation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(preservation)
        mergeButton = SettingsButton(title: L10n.tr(canChoose ? "Keep Both" : "Resume Sync"), target: self,
                                     action: canChoose ? #selector(merge) : #selector(resume))
        mergeButton.isEnabled = !canChoose || canMerge
        mergeButton.setAccessibilityIdentifier("syncReview.merge")
        if canChoose { mergeButton.toolTip = L10n.tr("Append Flomo after Island Note in the same memo. Both originals are backed up.") }
        footer.addArrangedSubview(mergeButton)
        let later = SettingsButton(title: L10n.tr("Decide Later"), target: self, action: #selector(cancel), quiet: true)
        later.keyEquivalent = "\u{1b}"
        footer.addArrangedSubview(later)

        for view in [header, columns, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            columns.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            columns.leadingAnchor.constraint(equalTo: header.leadingAnchor), columns.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            left.view.heightAnchor.constraint(equalTo: columns.heightAnchor), right.view.heightAnchor.constraint(equalTo: columns.heightAnchor),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22)
        ])
        window.initialFirstResponder = later
    }

    private func column(title: String, updated: String?, text: String, action: Selector, hint: String, enabled: Bool)
        -> (view: NSView, scroll: NSScrollView, button: SettingsButton) {
        let card = SettingsSurface(role: .card)
        let heading = NSStackView()
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 7
        heading.addArrangedSubview(label(title, size: 18, localized: false))
        let time = updated.map { L10n.format("Updated: %@", $0) } ?? L10n.tr("Update time unavailable")
        heading.addArrangedSubview(label(time, size: 13, secondary: true, wrapping: true, localized: false))
        heading.addArrangedSubview(label(L10n.format("%d characters", SyncDocument.count(text)), size: 13, secondary: true, localized: false))
        let scroll = Self.makeScrollView(text: text)
        scroll.setAccessibilityLabel(L10n.format("%@ copy", title))
        let button = SettingsButton(title: L10n.tr("Use This Copy"), target: self, action: action)
        button.isEnabled = enabled
        let effect = label(hint, size: 13, secondary: true)
        effect.alignment = .center
        for view in [heading, scroll, button, effect] { view.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            button.leadingAnchor.constraint(equalTo: heading.leadingAnchor), button.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            effect.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8), effect.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: heading.trailingAnchor), effect.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        return (card, scroll, button)
    }

    static func makeScrollView(text: String) -> NSScrollView {
        let scroll = SyncReviewScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        container.widthTracksTextView = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 200), textContainer: container)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false; view.drawsBackground = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 12)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: SettingsPalette.ink, .paragraphStyle: paragraph
        ]))
        scroll.documentView = view
        return scroll
    }

    private func label(_ key: String, size: CGFloat, secondary: Bool = false, wrapping: Bool = false, localized: Bool = true) -> NSTextField {
        let text = localized ? L10n.tr(key) : key
        let field = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size); field.textColor = secondary ? SettingsPalette.secondary : SettingsPalette.ink
        return field
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.language == .chinese ? Locale(identifier: "zh_CN") : .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func remoteDateText(_ value: String) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return dateText(date) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: value) { return dateText(date) }
        // An offset-free service timestamp has no known timezone. Show its
        // original representation rather than inventing an absolute date.
        return value
    }

    private func observeScrolling() {
        for scroll in [localScroll!, remoteScroll!] {
            let clip = scroll.contentView
            scrollBounds[ObjectIdentifier(scroll)] = clip.bounds
            clip.postsBoundsChangedNotifications = true
            scrollObservations.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll else { return }
                    let key = ObjectIdentifier(scroll)
                    let bounds = scroll.contentView.bounds
                    let previous = self.scrollBounds.updateValue(bounds, forKey: key)
                    // A resized viewport is layout, not a new scroll leader.
                    guard !self.synchronizingScroll, let previous, previous.size == bounds.size,
                          previous.minY != bounds.minY else { return }
                    self.lastScrolledView = scroll
                    if self.isScrollLocked { self.synchronizeScroll(from: scroll) }
                }
            })
        }
    }

    /// Match native vertical progress without another animation clock or text layout.
    /// Clamp elastic overscroll so it cannot pull the other copy beyond its ends.
    private func synchronizeScroll(from source: NSScrollView) {
        guard !synchronizingScroll else { return }
        let target = source === localScroll ? remoteScroll! : localScroll!
        let from = source.contentView, to = target.contentView
        let sourceRange = max(0, from.documentRect.height - from.bounds.height)
        guard sourceRange > 0 else { return }
        let progress = min(1, max(0, (from.bounds.minY - from.documentRect.minY) / sourceRange))
        let targetRange = max(0, to.documentRect.height - to.bounds.height)
        let y = to.documentRect.minY + progress * targetRange
        guard abs(to.bounds.minY - y) > 0.01 else { return }
        synchronizingScroll = true
        defer { synchronizingScroll = false }
        to.scroll(to: NSPoint(x: to.bounds.minX, y: y))
        target.reflectScrolledClipView(to)
    }

    @objc private func toggleScrollLock() {
        isScrollLocked = scrollLockButton.state == .on
        updateScrollLockAppearance(animated: true)
        if isScrollLocked { synchronizeScroll(from: lastScrolledView ?? localScroll) }
        logger.info("Comparison scroll lock: \(self.isScrollLocked, privacy: .public)")
    }

    private func updateScrollLockAppearance(animated: Bool) {
        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.16
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollLockButton.layer?.add(transition, forKey: "scroll-lock-symbol")
        }
        scrollLockButton.image = NSImage(systemSymbolName: isScrollLocked ? "lock.fill" : "lock.open",
                                        accessibilityDescription: nil)
        scrollLockButton.toolTip = L10n.tr(isScrollLocked ? "Unlock scrolling" : "Lock scrolling")
        scrollLockButton.setAccessibilityValue(isScrollLocked ? 1 : 0)
    }

    func windowDidEndLiveResize(_ notification: Notification) { prepareTextLayout() }

    deinit {
        for observation in scrollObservations { NotificationCenter.default.removeObserver(observation) }
    }

    @objc private func useLocal() { finish(.choose(.local)) }
    @objc private func useRemote() { finish(.choose(.remote)) }
    @objc private func merge() { finish(.choose(.merge)) }
    @objc private func resume() { finish(.resume) }
    @objc private func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ choice: SyncReviewAction?) {
        guard let continuation else { return }
        self.continuation = nil
        window?.close()
        continuation.resume(returning: choice)
    }
}

/// NSScrollView can install a document before Auto Layout gives it a viewport.
/// Keep wrapping tied to that viewport, including the first layout and resizing.
private final class SyncReviewScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let view = documentView as? NSTextView, contentSize.width > 0,
              abs(view.frame.width - contentSize.width) > 0.5 else { return }
        view.setFrameSize(NSSize(width: contentSize.width, height: max(view.frame.height, contentSize.height)))
    }
}
