import AppKit

@MainActor
enum FlomoSettings {
    static func show(_ sync: FlomoSync) {
        if sync.record.enabled, let conflict = sync.conflict {
            review(conflict, sync: sync)
            return
        }
        var draftToken = ""
        var draftID = sync.record.memoID ?? ""
        while true {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Flomo Sync")
            alert.informativeText = sync.status + "\n\n" + L10n.tr("Connect with a Flomo MAX personal token. Island Note keeps it in Keychain. Use Find Existing Memo to search by text. Leave the memo field empty only when creating a new note.")
            alert.addButton(withTitle: L10n.tr("Connect"))
            alert.addButton(withTitle: L10n.tr("Cancel"))
            alert.addButton(withTitle: sync.record.enabled ? L10n.tr("Pause Sync") : L10n.tr("Resume Sync"))
            alert.buttons[2].isEnabled = sync.record.memoID != nil && !sync.record.creationUncertain
            let controls = SecondaryActions()

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            let token = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 24))
            token.stringValue = draftToken
            token.placeholderString = L10n.tr("Personal token (blank keeps the saved token)")
            token.setAccessibilityLabel(L10n.tr("Flomo personal token"))
            let memo = NSTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 24))
            memo.placeholderString = L10n.tr("Existing Flomo memo URL or ID (optional)")
            memo.stringValue = draftID
            memo.setAccessibilityLabel(L10n.tr("Flomo memo URL or ID"))
            stack.addArrangedSubview(token)
            stack.addArrangedSubview(memo)
            let search = NSButton(title: L10n.tr("Find Existing Memo…"), target: controls, action: #selector(SecondaryActions.findMemo))
            stack.addArrangedSubview(search)
            let tokenHelp = NSButton(title: L10n.tr("Get Token"), target: controls, action: #selector(SecondaryActions.getToken))
            let syncNow = NSButton(title: L10n.tr("Sync Now"), target: controls, action: #selector(SecondaryActions.syncNow))
            syncNow.isEnabled = sync.record.enabled && sync.record.memoID != nil
            let secondary = NSStackView(views: [tokenHelp, syncNow]); secondary.spacing = 12
            stack.addArrangedSubview(secondary)
            stack.frame.size = NSSize(width: 390, height: 136)
            alert.accessoryView = stack
            NSApp.activate(ignoringOtherApps: true)
            let response = withExtendedLifetime(controls) { alert.runModal() }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    let entered = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let credential = entered.isEmpty ? try FlomoCredential.load() : entered, !credential.isEmpty else {
                        error(L10n.tr("Enter a Flomo personal token first.")); return
                    }
                    let id = try memoID(from: memo.stringValue)
                    if !entered.isEmpty { try FlomoCredential.save(credential) }
                    Task { await sync.connect(client: FlomoClient(token: credential), memoID: id) }
                } catch { self.error(error.localizedDescription) }
            case .alertThirdButtonReturn:
                if sync.record.enabled { sync.pause() } else { sync.resume() }
            case NSApplication.ModalResponse(rawValue: 1003):
                NSWorkspace.shared.open(URL(string: "https://help.flomoapp.com/advance/mcp/token.html")!)
                draftToken = token.stringValue; draftID = memo.stringValue
                continue
            case NSApplication.ModalResponse(rawValue: 1004):
                sync.request()
            case NSApplication.ModalResponse(rawValue: 1005):
                do {
                    draftToken = token.stringValue
                    draftID = memo.stringValue
                    let entered = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let credential = entered.isEmpty ? try FlomoCredential.load() : entered, !credential.isEmpty else {
                        error(L10n.tr("Enter your personal token to search your Flomo memos.")); continue
                    }
                    let picker = FlomoMemoPicker(client: FlomoClient(token: credential))
                    if let selected = picker.run() { draftID = selected.id }
                } catch { self.error(error.localizedDescription) }
                continue
            default: break
            }
            return
        }
    }

    private final class SecondaryActions: NSObject {
        @objc func findMemo() { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 1005)) }
        @objc func getToken() { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 1003)) }
        @objc func syncNow() { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 1004)) }
    }

    static func memoID(from input: String) throws -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return nil }
        let id: String
        if input.contains("://") {
            guard let url = URLComponents(string: input), url.scheme == "https",
                  ["v.flomoapp.com", "flomoapp.com"].contains(url.host ?? ""),
                  let value = url.queryItems?.first(where: { $0.name == "memo_id" })?.value else { throw SettingsError.invalidID }
            id = value
        } else { id = input }
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw SettingsError.invalidID }
        return id
    }

    private static func review(_ conflict: SyncConflict, sync: FlomoSync) {
        let alert = NSAlert()
        alert.messageText = sync.phase == .mergeRequired ? L10n.tr("Merge your two notes") : L10n.tr("Review sync differences")
        alert.informativeText = sync.status + L10n.tr("\n\nMerge Both keeps the Island Note text followed by the Flomo text in one document and the same memo. Both originals are backed up locally. If either copy changes during review, Island Note will ask you to review again.")
        alert.addButton(withTitle: L10n.tr("Use Island Note"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.addButton(withTitle: L10n.tr("Use Flomo"))
        alert.addButton(withTitle: L10n.tr("Pause Sync"))
        alert.addButton(withTitle: L10n.tr("Merge Both")).isEnabled = sync.record.pendingWrite == nil
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        for (title, text) in [("Island Note", conflict.local), ("Flomo", SyncDocument.fromFlomo(conflict.remote.content))] {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.addArrangedSubview(NSTextField(labelWithString: title))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 260))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.string = text
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            scroll.documentView = view
            column.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(column)
        }
        stack.frame.size = NSSize(width: 612, height: 290)
        alert.accessoryView = stack
        let result = alert.runModal()
        let choice: SyncChoice
        switch result {
        case .alertFirstButtonReturn: choice = .local
        case .alertThirdButtonReturn: choice = .remote
        case NSApplication.ModalResponse(rawValue: 1003): sync.pause(); return
        case NSApplication.ModalResponse(rawValue: 1004): choice = .merge
        default: return
        }
        Task { await sync.synchronize(choice: choice, reviewed: conflict) }
    }

    static func error(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Flomo Sync")
        alert.informativeText = message
        alert.runModal()
    }

    private enum SettingsError: LocalizedError {
        case invalidID
        var errorDescription: String? { L10n.tr("Enter a valid Flomo memo URL or ID.") }
    }
}
