import Foundation
import CryptoKit

/// The one local Markdown document edited by Island Note.
/// Writes are debounced while typing and flushed before the editor closes.
final class NoteStore {
    private enum SaveError: LocalizedError {
        case changedOutsideApp
        case documentNotLoaded

        var errorDescription: String? {
            switch self {
            case .changedOutsideApp:
                return L10n.tr("Island Note.md changed in another app. The Vault file was not overwritten. Copy your unsaved text before restarting, then resolve the two versions.")
            case .documentNotLoaded:
                return L10n.tr("The Vault document has not loaded. Saving is blocked to protect its existing contents.")
            }
        }
    }

    private(set) var fileURL: URL
    let configurationDirectory: URL
    private var lastLoadedContent: String?
    private var pending: String?
    private var saveWork: DispatchWorkItem?
    private var configurationError: Error?
    private var usesManagedFile: Bool
    private var scopedURL: URL?
    private var legacyDocumentPath: String?
    private let debounceInterval: TimeInterval = 0.18
    private(set) var lastErrorMessage: String?

    var onSaved: (() -> Void)?
    var onSyncNeeded: (() -> Void)?
    var onSaveError: ((String) -> Void)?

    init(fileURL: URL? = nil, configurationDirectory: URL? = nil) {
        let directory = configurationDirectory ?? Self.defaultDirectory
        self.configurationDirectory = directory
        if let fileURL {
            self.fileURL = fileURL
            configurationError = nil
            usesManagedFile = false
            legacyDocumentPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            return
        }
        let settings = directory.appendingPathComponent("settings.json")
        let managed = directory.appendingPathComponent("Island Note.md")
        do {
            if FileManager.default.fileExists(atPath: settings.path) {
                let config = try JSONDecoder().decode(NoteConfiguration.self, from: Data(contentsOf: settings))
                guard config.notePath.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
                if let bookmark = config.bookmark {
                    var stale = false
                    let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                           relativeTo: nil, bookmarkDataIsStale: &stale)
                    self.fileURL = resolved
                    if resolved.startAccessingSecurityScopedResource() { scopedURL = resolved }
                    if stale {
                        let refreshed = try resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        try Self.writeConfiguration(NoteConfiguration(notePath: resolved.path, bookmark: refreshed), directory: directory)
                    }
                } else { self.fileURL = URL(fileURLWithPath: config.notePath) }
                usesManagedFile = false
            } else {
                self.fileURL = managed
                usesManagedFile = true
            }
            configurationError = nil
        } catch {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            self.fileURL = managed
            usesManagedFile = false
            configurationError = error
        }
        if configurationError == nil { legacyDocumentPath = self.fileURL.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    private static func writeConfiguration(_ configuration: NoteConfiguration, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Validate and save the selection before releasing the previous document's access.
    /// An open failure keeps the current document and its pending text intact.
    func openExisting(_ url: URL) throws -> String {
        guard pending == nil || flushSync() else { throw SaveError.documentNotLoaded }
        let accessed = url.startAccessingSecurityScopedResource()
        var committed = false
        defer { if accessed && !committed { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        #if ISLAND_APP_STORE || ISLAND_TESTFLIGHT
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark: Data? = nil
        #endif
        try Self.writeConfiguration(NoteConfiguration(notePath: url.path, bookmark: bookmark), directory: configurationDirectory)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = accessed ? url : nil
        committed = true
        fileURL = url
        usesManagedFile = false
        configurationError = nil
        lastLoadedContent = text
        lastErrorMessage = nil
        return text
    }

    /// Save a new copy and switch to it. Never truncate an existing destination.
    func saveCopyAndSwitch(to url: URL) throws -> String {
        guard flushSync(), let text = lastLoadedContent else { throw SaveError.documentNotLoaded }
        try prepareSyncState()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let destinationState = syncStateURL(for: url)
        let previousState = syncStateURL
        let previousData = try FileManager.default.fileExists(atPath: previousState.path) ? Data(contentsOf: previousState) : nil
        // A save-location change keeps this logical note's connection. A stale
        // destination connection must never silently replace or redirect it.
        guard !FileManager.default.fileExists(atPath: destinationState.path) else { throw CocoaError(.fileWriteFileExists) }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        var destinationCreated = false
        do {
            if let previousData {
                // Pause first: interruption must never leave two active writers.
                var paused = try JSONDecoder().decode(SyncRecord.self, from: previousData)
                paused.enabled = false
                try JSONEncoder().encode(paused).write(to: previousState, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousState.path)
                try FileManager.default.createDirectory(at: destinationState.deletingLastPathComponent(), withIntermediateDirectories: true)
                try previousData.write(to: destinationState, options: .withoutOverwriting)
                destinationCreated = true
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationState.path)
            }
            return try openExisting(url)
        } catch {
            // Selection persistence failed: retain the old connection and leave
            // the new Markdown copy intact, without a second active connection.
            if let previousData {
                if destinationCreated { try FileManager.default.removeItem(at: destinationState) }
                try previousData.write(to: previousState, options: .atomic)
            }
            throw error
        }
    }

    var syncStateURL: URL { syncStateURL(for: fileURL) }

    private func syncStateURL(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return configurationDirectory.appendingPathComponent("Documents/" + key, isDirectory: true)
            .appendingPathComponent("flomo-sync.json")
    }

    /// Associate a legacy global connection with exactly its original document.
    /// Keep the original record as a recovery copy; never import it into later files.
    func prepareSyncState() throws {
        let legacy = configurationDirectory.appendingPathComponent("flomo-sync.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let marker = configurationDirectory.appendingPathComponent("legacy-sync-document.json")
        let identity = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        if FileManager.default.fileExists(atPath: marker.path) {
            let original = try JSONDecoder().decode(NoteConfiguration.self, from: Data(contentsOf: marker))
            guard original.notePath == identity else { return }
        } else {
            guard legacyDocumentPath == identity else { return }
            _ = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: legacy))
            try JSONEncoder().encode(NoteConfiguration(notePath: identity, bookmark: nil)).write(to: marker, options: .withoutOverwriting)
        }
        if !FileManager.default.fileExists(atPath: syncStateURL.path) {
            try FileManager.default.createDirectory(at: syncStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: legacy, to: syncStateURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: syncStateURL.path)
        }
    }

    /// The selected old settings directory must name the currently open note.
    /// Import paused so the user can review before any network operation.
    func importPreviousConnection(from directory: URL) throws {
        let settings = directory.appendingPathComponent("settings.json")
        let previousNote: URL
        if FileManager.default.fileExists(atPath: settings.path) {
            let configuration = try JSONDecoder().decode(NoteConfiguration.self, from: Data(contentsOf: settings))
            previousNote = URL(fileURLWithPath: configuration.notePath)
        } else { previousNote = directory.appendingPathComponent("Island Note.md") }
        guard previousNote.standardizedFileURL.resolvingSymlinksInPath() == fileURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var record = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: directory.appendingPathComponent("flomo-sync.json")))
        guard record.memoID != nil || record.creationUncertain || record.pendingWrite != nil else { throw CocoaError(.fileReadCorruptFile) }
        record.enabled = false
        try FileManager.default.createDirectory(at: syncStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: syncStateURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: syncStateURL.path)
    }

    static var defaultDirectory: URL {
        #if ISLAND_APP_STORE || ISLAND_TESTFLIGHT
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

private struct NoteConfiguration: Codable {
    let notePath: String
    let bookmark: Data?
}
