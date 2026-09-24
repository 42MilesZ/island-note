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
                alert.messageText = "Island Note could not save"
                alert.informativeText = store.lastErrorMessage ?? "Your text is still open. Check the red save indicator before quitting."
                alert.addButton(withTitle: "Keep Editing")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
