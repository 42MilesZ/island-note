import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandNoteController!
    private var store: NoteStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = NoteStore()
        controller = IslandNoteController(store: store)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushSync()
    }
}
