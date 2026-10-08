import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandNoteController!
    private var store: NoteStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = NoteStore()
        controller = IslandNoteController(store: store)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // MarkdownEngine publishes native edits to its binding on the next main-queue turn.
        // Let that update run before deciding whether it is safe to quit.
        DispatchQueue.main.async { [self] in
            controller.flushEditor()
            if store.flushSync() {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                let alert = NSAlert()
                alert.messageText = L10n.tr("Island Note could not save")
                alert.informativeText = store.lastErrorMessage ?? L10n.tr("Your text is still open. Check the red save indicator before quitting.")
                alert.addButton(withTitle: L10n.tr("Keep Editing"))
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
