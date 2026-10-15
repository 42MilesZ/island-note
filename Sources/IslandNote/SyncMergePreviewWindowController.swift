import AppKit

/// An editable, disposable draft. No file or network write happens in this sheet.
@MainActor
final class SyncMergePreviewWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var textView: NSTextView!
    private(set) var applyButton: SettingsButton!
    private(set) var cancelButton: SettingsButton!
    private(set) var validationLabel: NSTextField!
    private var countLabel: NSTextField!

    init(text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Merge preview")
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 400)
        super.init(window: window)
        window.delegate = self
        let root = SettingsSurface(role: .page)
        window.contentView = root
        let title = NSTextField(labelWithString: L10n.tr("Merge preview"))
        title.font = .systemFont(ofSize: 22); title.textColor = SettingsPalette.ink
        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = SettingsPalette.secondary
        let heading = NSStackView(views: [title, NSView(), countLabel])
        heading.alignment = .centerY; heading.spacing = 12
        let summary = NSTextField(wrappingLabelWithString: L10n.tr("Shared text appears once. Different text is kept. Edit the result below."))
        summary.font = .systemFont(ofSize: 13); summary.textColor = SettingsPalette.secondary

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.layer?.masksToBounds = true
        let card = SettingsSurface(role: .card)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
        textView.isRichText = false; textView.isEditable = true; textView.isSelectable = true
        textView.allowsUndo = true; textView.drawsBackground = false
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: SettingsPalette.ink,
            .paragraphStyle: SyncDiffTextView.paragraph
        ]))
        textView.delegate = self
        textView.setAccessibilityIdentifier("syncMerge.editor")
        textView.setAccessibilityLabel(L10n.tr("Merged text"))
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor), scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        validationLabel = NSTextField(wrappingLabelWithString: "")
        validationLabel.font = .systemFont(ofSize: 13); validationLabel.textColor = SettingsPalette.secondary
        validationLabel.setAccessibilityIdentifier("syncMerge.validation")
        cancelButton = SettingsButton(title: L10n.tr("Back to comparison"), target: self, action: #selector(cancel))
        cancelButton.setAccessibilityIdentifier("syncMerge.cancel")
        applyButton = SettingsButton(title: L10n.tr("Merge and Sync"), target: self, action: #selector(apply), emphasized: true)
        applyButton.setAccessibilityIdentifier("syncMerge.apply")
        let actions = NSStackView(views: [cancelButton, NSView(), applyButton])
        actions.spacing = 12; actions.alignment = .centerY
        for view in [heading, summary, card, validationLabel!, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22).isActive = true
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22).isActive = true
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            summary.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            card.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: validationLabel.topAnchor, constant: -10),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            validationLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        window.initialFirstResponder = textView
        updateValidation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func run(for parent: NSWindow) async -> String? {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            parent.beginSheet(window)
            window.makeFirstResponder(textView)
        }
    }

    func textDidChange(_ notification: Notification) { updateValidation() }
    private func updateValidation() {
        countLabel.stringValue = L10n.format("%d characters", SyncDocument.count(textView.string))
        let issue = SyncDocument.issue(in: textView.string)
            ?? (SyncDocument.transferFits(textView.string) ? nil : L10n.tr("The note fits locally but needs a little more room for Flomo formatting. Shorten it before syncing."))
        applyButton.isEnabled = issue == nil
        validationLabel.stringValue = issue ?? L10n.tr("Originals are backed up before replacement.")
    }
    @objc private func apply() {
        updateValidation()
        guard applyButton.isEnabled else { return }
        finish(textView.string)
    }
    @objc private func cancel() { dismiss() }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    func dismiss() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ text: String?) {
        guard let continuation else { return }
        self.continuation = nil
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil); window.close()
        }
        continuation.resume(returning: text)
    }
}
