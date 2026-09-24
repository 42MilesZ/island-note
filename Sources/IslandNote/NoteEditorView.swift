import AppKit
import SwiftUI
import MarkdownEngine

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

    var onTextChanged: ((String) -> Void)?
    var onRequestCollapse: (() -> Void)?
    var onRequestQuit: (() -> Void)?

    var string: String {
        get { model.text }
        set { model.text = newValue }
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
            onTextChanged: { [weak self] text in self?.onTextChanged?(text) },
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

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            featherView.leadingAnchor.constraint(equalTo: hostingView.leadingAnchor),
            featherView.trailingAnchor.constraint(equalTo: hostingView.trailingAnchor),
            featherView.topAnchor.constraint(equalTo: hostingView.topAnchor),
            featherView.bottomAnchor.constraint(equalTo: hostingView.bottomAnchor),

            savedDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            savedDot.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            savedDot.widthAnchor.constraint(equalToConstant: 6),
            savedDot.heightAnchor.constraint(equalToConstant: 6),
        ])
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
    }

    deinit {
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
    }

    func focus() {
        hostingView.layoutSubtreeIfNeeded()
        observeScrollPosition()
        if let textView = hostedTextView(in: hostingView) {
            window?.makeFirstResponder(textView)
        }
    }

    func blur() {
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
