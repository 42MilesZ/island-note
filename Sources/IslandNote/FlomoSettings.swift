import AppKit

@MainActor
enum FlomoSettings {
    static func show(_ sync: FlomoSync, refreshReview: Bool = true) async {
        guard !sync.isStopped else { return }
        if refreshReview, sync.record.enabled, [.conflict, .mergeRequired, .formattingChanged, .verifyWrite].contains(sync.phase) {
            await sync.prepareReview()
            guard !sync.isStopped else { return }
            if [.synced, .waiting].contains(sync.phase), sync.conflict == nil { return }
        }
        if !sync.requiresReconnection, let conflict = sync.conflict {
            let review = FlomoConflictWindowController(conflict: conflict, sync: sync)
            if let action = await review.run() {
                switch action {
                case .choose(let choice): await sync.synchronize(choice: choice, reviewed: conflict)
                case .merge(let text): await sync.synchronize(choice: .merge, reviewed: conflict, mergedText: text)
                case .resume: sync.resume()
                }
                // Preserve a rejected operation's reason on the comparison.
                // A new user choice still fetches and validates both copies.
                if sync.conflict != nil { await show(sync, refreshReview: sync.reviewError == nil) }
            }
            return
        }
        if [.connectionFailed, .offline, .unsupported, .tooLong, .failed, .rateLimited, .localChanged].contains(sync.phase)
            || (!sync.record.enabled && sync.record.reviewPhase != nil) {
            let alert = NSAlert()
            alert.messageText = sync.phase.title
            alert.informativeText = sync.status
            alert.addButton(withTitle: L10n.tr("OK"))
            alert.addButton(withTitle: sync.record.enabled ? L10n.tr("Sync Now") : L10n.tr("Resume Sync"))
            alert.buttons[1].isEnabled = !sync.isBusy
            if alert.runModal() == .alertSecondButtonReturn {
                if sync.record.enabled { sync.request() } else { sync.resume() }
            }
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

    @MainActor private final class SecondaryActions: NSObject {
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
