import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let preferences: AppPreferences
    private let diagnostics: InteractionDiagnostics
    var onFlomoToggle: ((Bool) -> Bool)?
    var onConfigureFlomo: (() -> Void)?
    var onDiagnosticToggle: (() -> Void)?
    var onExportDiagnostics: (() -> Void)?
    var onClearDiagnostics: (() -> Void)?
    var onLanguageChange: ((AppLanguage) -> Void)?
    var onPrivacy: (() -> Void)?
    var onClose: (() -> Void)?

    init(preferences: AppPreferences, diagnostics: InteractionDiagnostics) {
        self.preferences = preferences
        self.diagnostics = diagnostics
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 510),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func rebuild() {
        guard let window else { return }
        window.title = L10n.tr("Settings")
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        window.contentView = root
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24)
        ])
        func label(_ text: String, detail: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: L10n.tr(text))
            label.preferredMaxLayoutWidth = 432
            label.font = detail ? .systemFont(ofSize: 13) : .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = detail ? .secondaryLabelColor : .labelColor
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func separator() {
            let line = NSBox(); line.boxType = .separator
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let flomo = NSButton(checkboxWithTitle: L10n.tr("Flomo Sync"), target: self, action: #selector(toggleFlomo(_:)))
        flomo.font = .systemFont(ofSize: 14, weight: .semibold)
        flomo.state = preferences.flomoEnabled ? .on : .off
        flomo.setAccessibilityIdentifier("settings.flomo")
        stack.addArrangedSubview(flomo)
        label("Optional. Connect your own Flomo account to sync this note. Turning this off stops new sync requests and keeps both copies.", detail: true)
        let configure = NSButton(title: L10n.tr("Configure Flomo…"), target: self, action: #selector(configureFlomo))
        configure.isEnabled = preferences.flomoEnabled
        stack.addArrangedSubview(configure)
        separator()
        let diagnostic = NSButton(checkboxWithTitle: L10n.tr("Record Local Diagnostics"), target: self, action: #selector(toggleDiagnostics))
        diagnostic.font = .systemFont(ofSize: 14, weight: .semibold)
        diagnostic.state = diagnostics.isEnabled ? .on : .off
        diagnostic.setAccessibilityIdentifier("settings.diagnostics")
        stack.addArrangedSubview(diagnostic)
        label("Turn on, reproduce the problem, then export a report. Records stay on this Mac, without note text, account details or screenshots.", detail: true)
        let export = NSButton(title: L10n.tr("Export Report…"), target: self, action: #selector(exportDiagnostics))
        let clear = NSButton(title: L10n.tr("Clear Records"), target: self, action: #selector(clearDiagnostics))
        let hasRecords = !diagnostics.events.isEmpty || diagnostics.reportURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        export.isEnabled = diagnostics.isEnabled || hasRecords
        clear.isEnabled = hasRecords
        let row = NSStackView(views: [export, clear]); row.spacing = 12
        stack.addArrangedSubview(row)
        separator()
        label("Language")
        let language = NSPopUpButton()
        for option in AppLanguage.allCases {
            language.addItem(withTitle: option.title)
            language.lastItem?.representedObject = option.rawValue
        }
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: preferences.language) ?? 0)
        language.target = self; language.action = #selector(changeLanguage(_:))
        language.setAccessibilityIdentifier("settings.language")
        stack.addArrangedSubview(language)
        separator()
        let privacy = NSButton(title: L10n.tr("Privacy Policy"), target: self, action: #selector(showPrivacy))
        stack.addArrangedSubview(privacy)
        root.layoutSubtreeIfNeeded()
        let fittingHeight = stack.fittingSize.height + 48
        window.setContentSize(NSSize(width: 480, height: fittingHeight))
    }

    @objc private func toggleFlomo(_ sender: NSButton) { _ = onFlomoToggle?(sender.state == .on); rebuild() }
    @objc private func configureFlomo() { onConfigureFlomo?() }
    @objc private func toggleDiagnostics() { onDiagnosticToggle?(); rebuild() }
    @objc private func exportDiagnostics() { onExportDiagnostics?(); rebuild() }
    @objc private func clearDiagnostics() { onClearDiagnostics?(); rebuild() }
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String, let language = AppLanguage(rawValue: value) else { return }
        onLanguageChange?(language); rebuild()
    }
    @objc private func showPrivacy() { onPrivacy?() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
