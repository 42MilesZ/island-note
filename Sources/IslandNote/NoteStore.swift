import Foundation

/// The one local Markdown document edited by Island Note.
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
    private let configurationError: Error?
    private let usesManagedFile: Bool
    private let debounceInterval: TimeInterval = 0.18
    private(set) var lastErrorMessage: String?

    var onSaved: (() -> Void)?
    var onSyncNeeded: (() -> Void)?
    var onSaveError: ((String) -> Void)?

    init(fileURL: URL? = nil, configurationDirectory: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            configurationError = nil
            usesManagedFile = false
            return
        }
        let directory = configurationDirectory ?? Self.defaultDirectory

        let settings = directory.appendingPathComponent("settings.json")
        let managed = directory.appendingPathComponent("Island Note.md")
        do {
            if FileManager.default.fileExists(atPath: settings.path) {
                let config = try JSONDecoder().decode(NoteConfiguration.self, from: Data(contentsOf: settings))
                guard config.notePath.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
                self.fileURL = URL(fileURLWithPath: config.notePath)
                usesManagedFile = false
            } else {
                self.fileURL = managed
                usesManagedFile = true
            }
            configurationError = nil
        } catch {
            self.fileURL = managed
            usesManagedFile = false
            configurationError = error
        }
    }

    static var defaultDirectory: URL {
        #if ISLAND_TESTFLIGHT
        // Foundation resolves this inside the App Sandbox container.
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IslandNote", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IslandNote", isDirectory: true)
        #endif
    }

    var path: String { fileURL.path }

    func load() throws -> String {
        if let configurationError { throw configurationError }
        if usesManagedFile, !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try Data().write(to: fileURL, options: .withoutOverwriting) }
            catch CocoaError.fileWriteFileExists { /* Another launch created it; read that copy. */ }
        }
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
            try coordinatedWrite(text, expected: baseline)
            lastLoadedContent = text
            pending = nil
            lastErrorMessage = nil
            onSaved?()
            onSyncNeeded?()
            return true
        } catch {
            let message = "Could not save to \(fileURL.path): \(error.localizedDescription)"
            lastErrorMessage = message
            NSLog("IslandNote: %@", message)
            onSaveError?(message)
            return false
        }
    }

    #if !ISLAND_TESTFLIGHT
    func applySyncedText(_ text: String, expected: String) throws {
        guard pending == nil, lastLoadedContent == expected else { throw SyncFailure.localChanged }
        try coordinatedWrite(text, expected: expected)
        lastLoadedContent = text
        lastErrorMessage = nil
        onSaved?()
    }

    #endif

    private func coordinatedWrite(_ text: String, expected: String) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing,
                                       error: &coordinationError) { url in
            do {
                let disk = try String(contentsOf: url, encoding: .utf8)
                guard disk == expected else { throw SaveError.changedOutsideApp }
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}

private struct NoteConfiguration: Decodable {
    let notePath: String
}
