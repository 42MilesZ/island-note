import AppKit

/// A standard left-click menu keeps Quit discoverable even while the note is hidden.
@MainActor
final class StatusMenuController: NSObject {
    private let statusItem: NSStatusItem
    private let onOpen: () -> Void
    private let onSettings: () -> Void

    init(onOpen: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onSettings = onSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Island Note")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "IN" }
            button.toolTip = "Island Note"
            button.setAccessibilityLabel("Island Note")
        }
        statusItem.menu = makeMenu()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Island Note")
        let open = menu.addItem(withTitle: L10n.tr("Open Island Note"), action: #selector(openNote), keyEquivalent: "")
        open.target = self
        let settings = menu.addItem(withTitle: L10n.tr("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.tr("Quit Island Note"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = NSApp
        return menu
    }

    @objc private func openNote() { onOpen() }
    @objc private func showSettings() { onSettings() }

    deinit { NSStatusBar.system.removeStatusItem(statusItem) }
}
