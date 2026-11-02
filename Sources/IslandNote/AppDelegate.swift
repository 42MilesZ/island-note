import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandNoteController!
    private var store: NoteStore!
    private let logger = Logger(subsystem: "local.projects.island-note", category: "ApplicationLifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = NoteStore()
        controller = IslandNoteController(store: store)
        logger.info("Application ready with menu bar commands")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.info("Quit requested; flushing pending edits")
        // MarkdownEngine publishes native edits to its binding on the next main-queue turn.
        // Let that update run before deciding whether it is safe to quit.
        DispatchQueue.main.async { [self] in
            controller.flushEditor()
            if store.flushSync() {
                logger.info("Quit approved after saving")
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                logger.error("Quit cancelled because saving failed")
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
