import Foundation

/// The one Markdown document edited by Island Note, inside the local Obsidian vault.
/// Writes are debounced while typing and flushed before the editor closes.
final class NoteStore {
    private enum SaveError: LocalizedError {
        case changedOutsideApp
        case documentNotLoaded

        var errorDescription: String? {
            switch self {
            case .changedOutsideApp:
                return "Island Note.md changed in another app. The Vault file was not overwritten. Copy your unsaved text before restarting, then resolve the two versions."
            case .documentNotLoaded:
                return "The Vault document has not loaded. Saving is blocked to protect its existing contents."
            }
        }
    }

    let fileURL: URL
    private var lastLoadedContent: String?
    private var pending: String?
    private var saveWork: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.18
    private(set) var lastErrorMessage: String?

    var onSaved: (() -> Void)?
    var onSaveError: ((String) -> Void)?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/Miles-Vault/Dairy notes/Island Note.md")
    }

    var path: String { fileURL.path }

    func load() throws -> String {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        lastLoadedContent = text
        return text
    }

    /// Pick up edits made in Obsidian when there is no unsaved Island Note text.
    func refreshIfClean() throws -> String? {
        guard pending == nil else { return nil }
        let diskText = try String(contentsOf: fileURL, encoding: .utf8)
        guard diskText != lastLoadedContent else { return nil }
        lastLoadedContent = diskText
        return diskText
    }

    func save(_ text: String) {
        saveWork?.cancel()
        saveWork = nil
        if text == lastLoadedContent {
            pending = nil
            return
        }
        pending = text
        let work = DispatchWorkItem { [weak self] in
            _ = self?.flushSync()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    @discardableResult
    func flushSync() -> Bool {
        saveWork?.cancel()
        saveWork = nil
        guard let text = pending else { return true }
        do {
            guard let baseline = lastLoadedContent else { throw SaveError.documentNotLoaded }
            let diskText = try String(contentsOf: fileURL, encoding: .utf8)
            if diskText != baseline {
                throw SaveError.changedOutsideApp
            }
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            lastLoadedContent = text
            pending = nil
            lastErrorMessage = nil
            onSaved?()
            return true
        } catch {
            let message = "Could not save to \(fileURL.path): \(error.localizedDescription)"
            lastErrorMessage = message
            NSLog("IslandNote: %@", message)
            onSaveError?(message)
            return false
        }
    }
}
