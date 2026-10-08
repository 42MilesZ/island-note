import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let preferences: AppPreferences
    private let diagnostics: InteractionDiagnostics
    private let appVersion: String
    private var fileName: NSTextField!
    private var fileLocation: NSTextField!
    private var flomo: SettingsSwitch!
    private var diagnostic: SettingsSwitch!
    private var configure: SettingsButton!
    private var export: SettingsButton!
    private var clear: SettingsButton!
    private var infoPopover: NSPopover?
    var onFlomoToggle: ((Bool) -> Bool)?
    var onConfigureFlomo: (() -> Void)?
    var onDiagnosticToggle: (() -> Void)?
    var onExportDiagnostics: (() -> Void)?
    var onClearDiagnostics: (() -> Void)?
    var onPrivacy: (() -> Void)?
    var onClose: (() -> Void)?
    var notePath = ""
    var onOpenNote: (() -> Void)?
    var onSaveNoteAs: (() -> Void)?
    var onImportConnection: (() -> Void)?

    init(preferences: AppPreferences, diagnostics: InteractionDiagnostics,
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") {
        self.preferences = preferences
        self.diagnostics = diagnostics
        self.appVersion = appVersion
        let height = min(CGFloat(660), (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self
        window.center()
        buildPage()
        rebuild()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Refresh controls in place so focus, scrolling and animation remain continuous.
    func rebuild() {
        window?.title = L10n.tr("Settings")
        fileName.stringValue = notePath.isEmpty ? "Island Note.md" : URL(fileURLWithPath: notePath).lastPathComponent
        fileLocation.stringValue = notePath.isEmpty ? L10n.tr("Saved on this Mac")
            : NSString(string: URL(fileURLWithPath: notePath).deletingLastPathComponent().path).abbreviatingWithTildeInPath
        fileLocation.toolTip = notePath
        fileLocation.setAccessibilityValue(notePath)
        flomo.state = preferences.flomoEnabled ? .on : .off
        diagnostic.state = diagnostics.isEnabled ? .on : .off
        configure.isEnabled = preferences.flomoEnabled
        let hasRecords = !diagnostics.events.isEmpty || diagnostics.reportURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        export.isEnabled = diagnostics.isEnabled || hasRecords
        clear.isEnabled = hasRecords
    }
    private func buildPage() {
        guard let window else { return }
        let root = SettingsSurface(role: .page)
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll); window.contentView = root
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let document = SettingsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        let title = label("Settings", size: 28)
        stack.addArrangedSubview(title); stack.setCustomSpacing(24, after: title)
        let file = card(in: stack)
        file.addArrangedSubview(label("Note File", size: 15, secondary: true))
        fileName = label("Island Note.md", size: 18)
        fileName.lineBreakMode = .byTruncatingMiddle; file.addArrangedSubview(fileName)
        fileLocation = label("Saved on this Mac", size: 13, secondary: true)
        fileLocation.lineBreakMode = .byTruncatingMiddle; fileLocation.isSelectable = true
        fileLocation.setAccessibilityIdentifier("settings.notePath")
        file.addArrangedSubview(fileLocation); file.setCustomSpacing(18, after: fileLocation)
        let change = button("Change Save Location…", action: #selector(saveNoteAs))
        let open = button("Open Existing File…", action: #selector(openNote))
        file.addArrangedSubview(row([change, open]))
        change.toolTip = L10n.tr("Save this note at a new location. The previous file is kept and its sync is paused.")
        open.toolTip = L10n.tr("Edit an existing file and save back to it. It keeps its own Flomo connection.")
        let sync = card(in: stack)
        flomo = SettingsSwitch(title: L10n.tr("Flomo Sync"), target: self, action: #selector(toggleFlomo(_:)))
        flomo.setAccessibilityIdentifier("settings.flomo")
        sync.addArrangedSubview(heading("Flomo Sync", control: flomo))
        sync.addArrangedSubview(label("Optional sync with your own Flomo account.", secondary: true, wrapping: true))
        configure = button("Configure Flomo…", action: #selector(configureFlomo))
        let more = button("More Flomo Options", action: #selector(flomoOptions(_:)), symbol: "ellipsis")
        sync.addArrangedSubview(row([configure, more]))
        let records = card(in: stack)
        diagnostic = SettingsSwitch(title: L10n.tr("Record Local Diagnostics"), target: self, action: #selector(toggleDiagnostics))
        diagnostic.setAccessibilityIdentifier("settings.diagnostics")
        records.addArrangedSubview(heading("Local Diagnostics", control: diagnostic))
        records.addArrangedSubview(label("Helps troubleshoot interactions. Records stay on this Mac.", secondary: true, wrapping: true))
        export = button("Export Report…", action: #selector(exportDiagnostics))
        clear = button("Clear Records", action: #selector(clearDiagnostics))
        let info = button("About Local Diagnostics", action: #selector(showDiagnosticInfo(_:)), symbol: "info")
        records.addArrangedSubview(row([export, clear, info]))
        let privacy = button("Privacy Policy", action: #selector(showPrivacy), quiet: true)
        let identity = label("Island Note · " + appVersion, size: 13, secondary: true, localized: false)
        let footer = row([privacy, NSView(), identity]); stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        root.layoutSubtreeIfNeeded()
    }
    private func card(in parent: NSStackView) -> NSStackView {
        let surface = SettingsSurface(role: .card); surface.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView()
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(content)
        parent.addArrangedSubview(surface)
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalTo: parent.widthAnchor),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20)
        ])
        return content
    }
    private func label(_ text: String, size: CGFloat = 14, secondary: Bool = false, wrapping: Bool = false,
                       localized: Bool = true, width: CGFloat = 440) -> NSTextField {
        let value = localized ? L10n.tr(text) : text
        let label = wrapping ? NSTextField(wrappingLabelWithString: value) : NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: .regular)
        label.textColor = secondary ? SettingsPalette.secondary : SettingsPalette.ink
        label.preferredMaxLayoutWidth = width
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if wrapping { label.widthAnchor.constraint(equalToConstant: width).isActive = true }
        else { label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true }
        return label
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal
        row.alignment = .centerY; row.spacing = 10
        return row
    }
    private func heading(_ text: String, control: NSView) -> NSStackView {
        let heading = row([label(text, size: 17), NSView(), control])
        heading.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return heading
    }
    private func button(_ title: String, action: Selector, symbol: String? = nil, quiet: Bool = false) -> SettingsButton {
        let button = SettingsButton(title: symbol == nil ? L10n.tr(title) : "", target: self, action: action, quiet: quiet)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.tr(title))
            button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
        button.setAccessibilityLabel(L10n.tr(title))
        return button
    }
    @objc private func toggleFlomo(_ sender: NSButton) { _ = onFlomoToggle?(sender.state == .on); rebuild() }
    @objc private func configureFlomo() { onConfigureFlomo?() }
    @objc private func toggleDiagnostics() { onDiagnosticToggle?(); rebuild() }
    @objc private func exportDiagnostics() { onExportDiagnostics?(); rebuild() }
    @objc private func clearDiagnostics() { onClearDiagnostics?(); rebuild() }
    @objc private func showPrivacy() { onPrivacy?() }
    @objc private func openNote() { onOpenNote?(); rebuild() }
    @objc private func saveNoteAs() { onSaveNoteAs?(); rebuild() }
    @objc private func importConnection() { onImportConnection?(); rebuild() }
    @objc private func flomoOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let restore = NSMenuItem(title: L10n.tr("Restore Previous Flomo Connection…"), action: #selector(importConnection), keyEquivalent: "")
        restore.target = self; menu.addItem(restore)
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 4), in: sender)
    }
    @objc private func showDiagnosticInfo(_ sender: NSButton) {
        let controller = NSViewController()
        let description = label("Turn on, reproduce the problem, then export a report. Records stay on this Mac, without note text, account details or screenshots.", wrapping: true, width: 300)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 110))
        description.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(description)
        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            description.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            description.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            description.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])
        controller.view = view
        let popover = NSPopover(); popover.contentViewController = controller
        popover.behavior = .transient; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        infoPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    func windowWillClose(_ notification: Notification) { infoPopover?.close(); onClose?() }
}
private final class SettingsDocument: NSView { override var isFlipped: Bool { true } }
