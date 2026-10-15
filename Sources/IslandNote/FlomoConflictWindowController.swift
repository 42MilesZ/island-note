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
    private(set) var resumeButton: SettingsButton?
    private(set) var moreButton: SettingsButton!
    private(set) var moreMenu = NSMenu()
    private(set) var scrollLockButton: SettingsButton!
    private(set) var isScrollLocked = true
    private var synchronizingScroll = false
    private weak var lastScrolledView: NSScrollView?
    private var scrollBounds: [ObjectIdentifier: NSRect] = [:]
    private var scrollObservations: [NSObjectProtocol] = []
    private var comparisonTask: Task<Void, Never>?
    private var comparisonWork: Task<SyncDiff, Never>?
    private(set) var comparison: SyncDiff?
    private(set) var presentation: SyncDiffPresentation?
    struct AlignedBlock { let top: CGFloat; let height: CGFloat; let changed: Bool }
    private(set) var alignedBlocks: [AlignedBlock] = []
    private(set) var layoutPassCount = 0
    private(set) var previousDifferenceButton: SettingsButton!
    private(set) var nextDifferenceButton: SettingsButton!
    private(set) var differenceLabel: NSTextField!
    private(set) var collapseMenuItem: NSMenuItem!
    private(set) var isUnchangedCollapsed = false
    private var layoutWidths: [CGFloat] = []
    private var documentHeight: CGFloat = 0
    private var selectedDifference = -1
    private var canChooseCopy = false
    private var canCombine = false
    private var isResizing = false
    private var navigationTimer: Timer?
    private let logger = Logger(subsystem: "local.projects.island-note", category: "SyncReview")

    convenience init(conflict: SyncConflict, sync: FlomoSync) {
        self.init(conflict: conflict, phase: sync.phase, lastVerifiedAt: sync.record.lastVerifiedAt,
                  canChoose: sync.record.enabled && !sync.isStopped,
                  canMerge: sync.record.enabled && sync.record.pendingWrite == nil && sync.record.pendingMerge == nil,
                  reviewError: sync.reviewError,
                  mergeUnavailableReason: sync.record.pendingMerge != nil ? "Previous merge is awaiting verification."
                    : sync.record.pendingWrite != nil ? "Last upload is awaiting verification." : nil)
    }

    init(conflict: SyncConflict, phase: SyncPhase, lastVerifiedAt: Date?, canChoose: Bool, canMerge: Bool, reviewError: String? = nil,
         mergeUnavailableReason: String? = nil, preparedComparison: SyncDiff? = nil) {
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
        canChooseCopy = canChoose; canCombine = canChoose && canMerge
        build(conflict: conflict, phase: phase, lastVerifiedAt: lastVerifiedAt, canChoose: canChoose, canMerge: canMerge,
              reviewError: reviewError, mergeUnavailableReason: mergeUnavailableReason)
        observeScrolling()
        if let preparedComparison { installComparison(preparedComparison) }
        else {
            let local = conflict.local, remote = SyncDocument.fromFlomo(conflict.remote.content)
            let start = ProcessInfo.processInfo.systemUptime
            let work = Task.detached(priority: .userInitiated) { SyncDiff.compare(left: local, right: remote) }
            comparisonWork = work
            comparisonTask = Task { [weak self] in
                let result = await work.value
                guard !Task.isCancelled, let self else { return }
                self.logger.info("Diff computed in \((ProcessInfo.processInfo.systemUptime - start) * 1000, privacy: .public) ms; blocks=\(result.blocks.count, privacy: .public), coarse=\(result.usedCoarseComparison, privacy: .public)")
                self.installComparison(result)
            }
        }
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

    private func installComparison(_ comparison: SyncDiff) {
        self.comparison = comparison
        rebuildPresentation()
        localButton.isEnabled = canChooseCopy; remoteButton.isEnabled = canChooseCopy
        moreMenu.items.first?.isEnabled = canCombine
        collapseMenuItem.isEnabled = comparison.blocks.contains { $0.kind == .equal && min($0.leftLineCount, $0.rightLineCount) > 14 }
        differenceLabel.toolTip = comparison.usedCoarseComparison
            ? L10n.tr("Large changes use block highlighting to keep comparison responsive.") : nil
        if !differenceIndices.isEmpty { revealDifference(0, animated: false) }
    }

    private var differenceIndices: [Int] = []
    private func rebuildPresentation() {
        guard let comparison else { return }
        let presentation = SyncDiffPresentation(diff: comparison, collapseUnchanged: isUnchangedCollapsed)
        self.presentation = presentation
        for (view, side, isLeft) in [(localScroll.documentView as! SyncDiffTextView, presentation.left, true),
                                     (remoteScroll.documentView as! SyncDiffTextView, presentation.right, false)] {
            let folded = presentation.blocks.filter(\.folded).map { isLeft ? $0.left : $0.right }
            view.present(side, folded: folded)
        }
        differenceIndices = presentation.blocks.indices.filter { presentation.blocks[$0].changed }
        layoutWidths = []; alignedBlocks = []
        prepareTextLayout()
        updateDifferencePosition(from: lastScrolledView ?? localScroll)
    }

    /// Layout runs only when the presentation or viewport width changes. Padding
    /// belongs to paragraph layout, never to the text or the clipboard.
    func prepareTextLayout() {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let presentation else { return }
        let scrolls = [localScroll!, remoteScroll!]
        let widths = scrolls.map { $0.contentSize.width }
        let oldPositions = scrolls.map { position(in: $0) }
        synchronizingScroll = true
        defer { synchronizingScroll = false }
        if widths != layoutWidths {
            let start = ProcessInfo.processInfo.systemUptime
            let views = scrolls.map { $0.documentView as! SyncDiffTextView }
            let leftHeights = views[0].measure(width: widths[0], ranges: presentation.blocks.map(\.left))
            let rightHeights = views[1].measure(width: widths[1], ranges: presentation.blocks.map(\.right))
            var leftGaps: [(NSRange, CGFloat)] = [], rightGaps: [(NSRange, CGFloat)] = []
            var blocks: [AlignedBlock] = [], top: CGFloat = 12
            for index in presentation.blocks.indices {
                let height = ceil(max(leftHeights[index], rightHeights[index]))
                let block = presentation.blocks[index]
                blocks.append(AlignedBlock(top: top, height: height, changed: block.changed))
                leftGaps.append((block.left, height - leftHeights[index]))
                rightGaps.append((block.right, height - rightHeights[index]))
                top += height
            }
            alignedBlocks = blocks; documentHeight = top + 12
            for (index, view) in views.enumerated() {
                view.align(gaps: index == 0 ? leftGaps : rightGaps, height: max(documentHeight, scrolls[index].contentSize.height))
                view.decorations = blocks.enumerated().map { blockIndex, geometry in
                    let block = presentation.blocks[blockIndex]
                    return SyncDiffTextView.Decoration(top: geometry.top, height: geometry.height,
                                                       changed: index == 0 ? block.leftChanged : block.rightChanged,
                                                       missing: block.changed && (index == 0 ? block.left : block.right).length == 0)
                }
            }
            layoutWidths = widths; layoutPassCount += 1
            logger.info("Aligned diff layout: \(blocks.count, privacy: .public) blocks in \((ProcessInfo.processInfo.systemUptime - start) * 1000, privacy: .public) ms")
        } else {
            for scroll in scrolls {
                (scroll.documentView as? SyncDiffTextView)?.setDocumentHeight(max(documentHeight, scroll.contentSize.height))
            }
        }
        for (index, scroll) in scrolls.enumerated() {
            let position = oldPositions[index]
            let offset = position.index >= 0 && position.index < alignedBlocks.count
                ? alignedBlocks[position.index].top + position.fraction * alignedBlocks[position.index].height : 0
            setScroll(scroll, offset: offset)
            scrollBounds[ObjectIdentifier(scroll)] = scroll.contentView.bounds
        }
        if isScrollLocked {
            let source = lastScrolledView ?? localScroll!
            let target = source === localScroll ? remoteScroll! : localScroll!
            setScroll(target, offset: source.contentView.bounds.minY - source.contentView.documentRect.minY)
        }
    }

    private func position(in scroll: NSScrollView) -> (index: Int, fraction: CGFloat) {
        let offset = scroll.contentView.bounds.minY - scroll.contentView.documentRect.minY
        guard !alignedBlocks.isEmpty, offset > 12 else { return (-1, 0) }
        var low = 0, high = alignedBlocks.count
        while low < high {
            let mid = (low + high) / 2
            if alignedBlocks[mid].top <= offset { low = mid + 1 } else { high = mid }
        }
        let index = max(0, low - 1), block = alignedBlocks[index]
        return (index, min(1, max(0, (offset - block.top) / max(1, block.height))))
    }

    private func setScroll(_ scroll: NSScrollView, offset: CGFloat) {
        let clip = scroll.contentView
        let range = max(0, clip.documentRect.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.documentRect.minY + min(range, max(0, offset))))
        scroll.reflectScrolledClipView(clip)
    }

    private func navigationButton(symbol: String, title: String, action: Selector) -> SettingsButton {
        let button = SettingsButton(title: "", target: self, action: action, height: 28)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly; button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.setAccessibilityLabel(L10n.tr(title)); button.toolTip = L10n.tr(title)
        button.isEnabled = false
        return button
    }

    private func updateDifferencePosition(from scroll: NSScrollView) {
        guard !differenceIndices.isEmpty else {
            differenceLabel.stringValue = comparison == nil ? L10n.tr("Preparing comparison…") : L10n.tr("No differences")
            previousDifferenceButton.isEnabled = false; nextDifferenceButton.isEnabled = false
            return
        }
        let offset = scroll.contentView.bounds.minY - scroll.contentView.documentRect.minY + 44
        var low = 0, high = differenceIndices.count
        while low < high {
            let mid = (low + high) / 2
            if alignedBlocks[differenceIndices[mid]].top <= offset { low = mid + 1 } else { high = mid }
        }
        showDifferencePosition(max(0, low - 1))
    }

    private func showDifferencePosition(_ index: Int) {
        selectedDifference = index
        let text = L10n.format("Difference %d of %d", index + 1, differenceIndices.count)
        if differenceLabel.stringValue != text { differenceLabel.stringValue = text }
        previousDifferenceButton.isEnabled = index > 0
        nextDifferenceButton.isEnabled = index + 1 < differenceIndices.count
    }

    private func revealDifference(_ index: Int, animated: Bool) {
        guard differenceIndices.indices.contains(index) else { return }
        navigationTimer?.invalidate(); navigationTimer = nil
        let target = max(0, alignedBlocks[differenceIndices[index]].top - 40)
        showDifferencePosition(index)
        let scrolls = [localScroll!, remoteScroll!]
        let origins = scrolls.map { $0.contentView.bounds.minY - $0.contentView.documentRect.minY }
        func apply(_ fraction: CGFloat) {
            synchronizingScroll = true
            for (side, scroll) in scrolls.enumerated() { setScroll(scroll, offset: origins[side] + (target - origins[side]) * fraction) }
            synchronizingScroll = false
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { apply(1); return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.24)
                // Explicit ease-in-out, resuming from the current native origin.
                let eased = progress * progress * (3 - 2 * progress)
                self.synchronizingScroll = true
                for (side, scroll) in scrolls.enumerated() {
                    self.setScroll(scroll, offset: origins[side] + (target - origins[side]) * eased)
                }
                self.synchronizingScroll = false
                if progress >= 1 { timer.invalidate(); self.navigationTimer = nil }
            }
        }
        navigationTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func previousDifference() { revealDifference(max(0, selectedDifference - 1), animated: true) }
    @objc private func nextDifference() { revealDifference(min(differenceIndices.count - 1, selectedDifference + 1), animated: true) }
    @objc private func toggleUnchanged() {
        navigationTimer?.invalidate(); navigationTimer = nil
        let index = max(0, selectedDifference)
        isUnchangedCollapsed.toggle(); collapseMenuItem.state = isUnchangedCollapsed ? .on : .off
        rebuildPresentation()
        if !differenceIndices.isEmpty { revealDifference(min(index, differenceIndices.count - 1), animated: false) }
    }

    private func build(conflict: SyncConflict, phase: SyncPhase, lastVerifiedAt: Date?, canChoose: Bool, canMerge: Bool,
                       reviewError: String?, mergeUnavailableReason: String?) {
        guard let window else { return }
        let root = SettingsSurface(role: .page)
        window.contentView = root
        let header = NSStackView()
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        let title = label("Choose one copy for both", size: 26)
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
        moreButton = SettingsButton(title: "", target: self, action: #selector(showMore))
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        moreButton.imagePosition = .imageOnly
        moreButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        moreButton.setAccessibilityIdentifier("syncReview.more")
        moreButton.setAccessibilityLabel(L10n.tr("More options"))
        moreButton.toolTip = L10n.tr("More options")
        moreMenu.autoenablesItems = false
        let combine = NSMenuItem(title: L10n.tr("Append Both Full Copies"), action: #selector(merge), keyEquivalent: "")
        combine.identifier = NSUserInterfaceItemIdentifier("syncReview.combine")
        combine.target = self; combine.isEnabled = false
        combine.toolTip = L10n.tr("Append Flomo after Island Note in the same memo. Both originals are backed up.")
        moreMenu.addItem(combine)
        let blockedReason = !canChoose ? "Sync is paused. Resume to apply a choice."
            : !canMerge ? (mergeUnavailableReason ?? "A previous change is awaiting verification.") : nil
        if let blockedReason {
            let reason = NSMenuItem(title: L10n.tr(blockedReason), action: nil, keyEquivalent: "")
            reason.isEnabled = false; moreMenu.addItem(reason)
            combine.toolTip = L10n.tr(blockedReason)
        }
        moreMenu.addItem(.separator())
        collapseMenuItem = NSMenuItem(title: L10n.tr("Collapse unchanged text"), action: #selector(toggleUnchanged), keyEquivalent: "")
        collapseMenuItem.target = self; collapseMenuItem.isEnabled = false
        moreMenu.addItem(collapseMenuItem)
        let later = NSMenuItem(title: L10n.tr("Decide Later"), action: #selector(cancel), keyEquivalent: "")
        later.identifier = NSUserInterfaceItemIdentifier("syncReview.later")
        later.target = self; moreMenu.addItem(later)
        let controls = NSStackView(views: [scrollLockButton, moreButton])
        controls.spacing = 8
        let titleRow = NSStackView(views: [title, NSView(), controls])
        titleRow.orientation = .horizontal; titleRow.alignment = .centerY; titleRow.spacing = 16
        header.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        let timeRow = NSStackView(views: [
            SyncReviewMetadataTag(symbol: "arrow.triangle.2.circlepath", key: "Last sync",
                                  value: lastVerifiedAt.map { Self.dateText($0, compact: true) } ?? L10n.tr("No verified sync"),
                                  detail: lastVerifiedAt.map(Self.dateText)),
            SyncReviewMetadataTag(symbol: "clock", key: "Compared",
                                  value: Self.dateText(conflict.capturedAt, compact: true), detail: Self.dateText(conflict.capturedAt))
        ])
        timeRow.spacing = 10
        header.addArrangedSubview(timeRow)
        let warning: String?
        switch phase {
        case .connectionFailed, .offline, .authorizationRequired:
            warning = L10n.tr("Could not refresh. These are the last captured copies.")
        case .verifyWrite, .formattingChanged:
            warning = canChoose && !canMerge ? L10n.tr("Append unavailable: ") + L10n.tr(blockedReason!) : L10n.tr("Last upload unconfirmed.")
        default:
            warning = nil
        }
        if let warning = reviewError ?? warning ?? (canChoose && !canMerge ? L10n.tr("Append unavailable: ") + L10n.tr(blockedReason!) : nil) {
            let field = label(warning, size: 13, secondary: true, wrapping: true, localized: false)
            field.setAccessibilityIdentifier("syncReview.warning")
            header.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal; toolbar.alignment = .centerY; toolbar.spacing = 8
        let legend = label("Highlighted text differs between copies", size: 13, secondary: true)
        legend.setAccessibilityIdentifier("syncReview.legend")
        differenceLabel = label("Preparing comparison…", size: 13, secondary: true)
        differenceLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        differenceLabel.setAccessibilityIdentifier("syncReview.differencePosition")
        differenceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previousDifferenceButton = navigationButton(symbol: "chevron.up", title: "Previous difference", action: #selector(previousDifference))
        nextDifferenceButton = navigationButton(symbol: "chevron.down", title: "Next difference", action: #selector(nextDifference))
        for view in [legend, NSView(), differenceLabel!, previousDifferenceButton!, nextDifferenceButton!] {
            toolbar.addArrangedSubview(view)
        }

        let columns = NSStackView()
        columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 20; columns.distribution = .fillEqually
        let left = column(title: "Island Note", updated: conflict.localUpdatedAt.map { Self.dateText($0, compact: true) },
                          fullDate: conflict.localUpdatedAt.map(Self.dateText), text: conflict.local,
                          action: #selector(useLocal), buttonTitle: "Use Island Note", enabled: false)
        let right = column(title: "Flomo", updated: Self.remoteDateText(conflict.remote.updatedAt, compact: true),
                           fullDate: Self.remoteDateText(conflict.remote.updatedAt), text: SyncDocument.fromFlomo(conflict.remote.content),
                           action: #selector(useRemote), buttonTitle: "Use Flomo", enabled: false)
        localScroll = left.scroll; localButton = left.button
        remoteScroll = right.scroll; remoteButton = right.button
        localButton.setAccessibilityIdentifier("syncReview.local")
        remoteButton.setAccessibilityIdentifier("syncReview.remote")
        localButton.setAccessibilityLabel(L10n.tr("Use Island Note for both copies"))
        remoteButton.setAccessibilityLabel(L10n.tr("Use Flomo for both copies"))
        columns.addArrangedSubview(left.view); columns.addArrangedSubview(right.view)

        let footer = NSStackView()
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 12
        let shield = NSImageView(image: NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)!)
        shield.contentTintColor = SettingsPalette.secondary
        shield.widthAnchor.constraint(equalToConstant: 14).isActive = true
        shield.heightAnchor.constraint(equalToConstant: 14).isActive = true
        footer.addArrangedSubview(shield)
        let preservation = label(canChoose ? "Originals are backed up before replacement." : "Sync is paused. Resume to apply a choice.",
                                 size: 13, secondary: true, wrapping: true)
        preservation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(preservation)
        footer.addArrangedSubview(NSView())
        if !canChoose {
            let resume = SettingsButton(title: L10n.tr("Resume Sync"), target: self, action: #selector(resume))
            resume.setAccessibilityIdentifier("syncReview.resume")
            resumeButton = resume; footer.addArrangedSubview(resume)
        }

        for view in [header, toolbar, columns, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: header.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            columns.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 16),
            columns.leadingAnchor.constraint(equalTo: header.leadingAnchor), columns.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            left.view.heightAnchor.constraint(equalTo: columns.heightAnchor), right.view.heightAnchor.constraint(equalTo: columns.heightAnchor),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22)
        ])
        window.initialFirstResponder = localScroll.documentView
    }

    private func column(title: String, updated: String?, fullDate: String?, text: String, action: Selector, buttonTitle: String, enabled: Bool)
        -> (view: NSView, scroll: NSScrollView, button: SettingsButton) {
        let card = SettingsSurface(role: .card)
        let heading = NSStackView()
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 8
        let count = SyncReviewMetadataTag(symbol: "text.alignleft", value: L10n.format("%d characters", SyncDocument.count(text)))
        let name = NSStackView(views: [label(title, size: 18, localized: false), NSView(), count])
        name.alignment = .centerY; name.spacing = 8
        heading.addArrangedSubview(name)
        name.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        let time = SyncReviewMetadataTag(symbol: "clock", key: updated == nil ? nil : "Updated",
                                         value: updated ?? L10n.tr("Update time unavailable"), detail: fullDate)
        heading.addArrangedSubview(time)
        time.widthAnchor.constraint(lessThanOrEqualTo: heading.widthAnchor).isActive = true
        let scroll = Self.makeScrollView(text: text)
        scroll.setAccessibilityLabel(L10n.format("%@ copy", title))
        let button = SettingsButton(title: L10n.tr(buttonTitle), target: self, action: action, emphasized: true)
        button.isEnabled = enabled
        for view in [heading, scroll, button] { view.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18), heading.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            heading.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            button.leadingAnchor.constraint(equalTo: heading.leadingAnchor), button.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
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
        let view = SyncDiffTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 200), textContainer: container)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false; view.drawsBackground = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 24, height: 12)
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

    static func dateText(_ date: Date) -> String { dateText(date, compact: false) }

    static func dateText(_ date: Date, compact: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.language == .chinese ? Locale(identifier: "zh_CN") : .current
        formatter.dateFormat = compact ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func remoteDateText(_ value: String, compact: Bool = false) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return dateText(date, compact: compact) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: value) { return dateText(date, compact: compact) }
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
                    guard !self.synchronizingScroll, !self.isResizing, let previous, previous.size == bounds.size,
                          previous.minY != bounds.minY else { return }
                    self.navigationTimer?.invalidate(); self.navigationTimer = nil
                    self.lastScrolledView = scroll
                    if self.isScrollLocked { self.synchronizeScroll(from: scroll) }
                    self.updateDifferencePosition(from: scroll)
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
        let targetRange = max(0, to.documentRect.height - to.bounds.height)
        let y = to.documentRect.minY + min(targetRange, max(0, from.bounds.minY - from.documentRect.minY))
        guard abs(to.bounds.minY - y) > 0.01 else { return }
        synchronizingScroll = true
        defer { synchronizingScroll = false }
        to.scroll(to: NSPoint(x: to.bounds.minX, y: y))
        target.reflectScrolledClipView(to)
    }

    @objc private func toggleScrollLock() {
        navigationTimer?.invalidate(); navigationTimer = nil
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

    func windowWillStartLiveResize(_ notification: Notification) { isResizing = true; navigationTimer?.invalidate(); navigationTimer = nil }
    func windowDidEndLiveResize(_ notification: Notification) { isResizing = false; prepareTextLayout() }

    deinit {
        comparisonTask?.cancel(); comparisonWork?.cancel(); navigationTimer?.invalidate()
        for observation in scrollObservations { NotificationCenter.default.removeObserver(observation) }
    }

    @objc private func useLocal() { finish(.choose(.local)) }
    @objc private func useRemote() { finish(.choose(.remote)) }
    @objc private func merge() { finish(.choose(.merge)) }
    @objc private func resume() { finish(.resume) }
    @objc private func cancel() { finish(nil) }
    override func cancelOperation(_ sender: Any?) { finish(nil) }
    @objc private func showMore() {
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }
    func windowWillClose(_ notification: Notification) {
        comparisonTask?.cancel(); comparisonWork?.cancel(); navigationTimer?.invalidate()
        finish(nil)
    }
    private func finish(_ choice: SyncReviewAction?) {
        guard let continuation else { return }
        self.continuation = nil
        window?.close()
        continuation.resume(returning: choice)
    }
}

/// Read-only metadata stays smaller and quieter than the two selection buttons.
private final class SyncReviewMetadataTag: NSStackView {
    init(symbol: String, key: String? = nil, value: String, detail: String? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 6
        edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.cornerCurve = .continuous
        setHuggingPriority(.required, for: .horizontal)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = SettingsPalette.secondary
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 12), icon.heightAnchor.constraint(equalToConstant: 12)])
        addArrangedSubview(icon)
        if let key {
            let field = NSTextField(labelWithString: L10n.tr(key))
            field.font = .systemFont(ofSize: 13); field.textColor = SettingsPalette.secondary
            field.setAccessibilityElement(false)
            addArrangedSubview(field)
        }
        let field = NSTextField(labelWithString: value)
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.textColor = SettingsPalette.ink
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityElement(false)
        addArrangedSubview(field)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        let full = [key.map { L10n.tr($0) }, detail ?? value].compactMap { $0 }.joined(separator: ": ")
        toolTip = full
        setAccessibilityIdentifier("syncReview.metadata")
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(full)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = SettingsPalette.subtle.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
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
