import AppKit

@MainActor
enum PrivacyPolicyWindow {
    private static var controller: NSWindowController?
    static var isVisible: Bool { controller?.window?.isVisible == true }

    static func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Privacy Policy")
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        text.backgroundColor = .white
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 24, height: 20)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        if let url = L10n.resource("Privacy", extension: "html"), let data = try? Data(contentsOf: url),
           let content = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
            text.textStorage?.setAttributedString(content)
        } else {
            text.string = L10n.tr("Privacy policy could not be opened. Please reopen the app.")
        }
        scroll.documentView = text
        window.contentView = scroll
        window.center()
        controller?.close()
        controller = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
    }
}
