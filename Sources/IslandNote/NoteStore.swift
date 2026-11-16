import Foundation
import CryptoKit

/// The one local Markdown document edited by Island Note.
/// Writes are debounced while typing and flushed before the editor closes.
final class NoteStore {
    private enum SaveError: LocalizedError {
        case changedOutsideApp
        case documentNotLoaded
        case documentMissing(String)

        var errorDescription: String? {
            switch self {
            case .changedOutsideApp:
                return L10n.tr("Island Note.md changed in another app. The Vault file was not overwritten. Copy your unsaved text before restarting, then resolve the two versions.")
            case .documentNotLoaded:
                return L10n.tr("The Vault document has not loaded. Saving is blocked to protect its existing contents.")
            case .documentMissing(let path):
                return L10n.format("%@ was moved, renamed or deleted. Open Settings and choose Open Existing File… to select it again.", path)
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
    /// Bookmark of the open document. Bookmarks resolve by file identity, so a
    /// note moved or renamed in Finder or Obsidian is followed to its new path.
    private var bookmarkData: Data?
    private var legacyDocumentPath: String?
    private let debounceInterval: TimeInterval = 0.18
    private(set) var lastErrorMessage: String?

    var onSaveState: ((LocalSaveState) -> Void)?
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
        self.fileURL = managed
        usesManagedFile = false
        do {
            if FileManager.default.fileExists(atPath: settings.path) {
                let config = try JSONDecoder().decode(NoteConfiguration.self, from: Data(contentsOf: settings))
                guard config.notePath.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
                self.fileURL = URL(fileURLWithPath: config.notePath)
                if let bookmark = config.bookmark {
                    var stale = false
                    let resolved: URL
                    do {
                        resolved = try URL(resolvingBookmarkData: bookmark, options: Self.bookmarkResolutionOptions,
                                           relativeTo: nil, bookmarkDataIsStale: &stale)
                    } catch {
                        guard Self.isMissingFile(error) else { throw error }
                        // A deleted file can invalidate its bookmark. Keep the saved path.
                        resolved = self.fileURL
                    }
                    self.fileURL = resolved
                    if Self.usesSecurityScope, resolved.startAccessingSecurityScopedResource() { scopedURL = resolved }
                    bookmarkData = bookmark
                    if (stale || resolved.path != config.notePath),
                       let refreshed = try? Self.makeBookmark(for: resolved) {
                        bookmarkData = refreshed
                        try Self.writeConfiguration(NoteConfiguration(notePath: resolved.path, bookmark: refreshed), directory: directory)
                    }
                } else {
                    let url = URL(fileURLWithPath: config.notePath)
                    self.fileURL = url
                    // Upgrade path-only settings so later moves can be followed.
                    if let bookmark = try? Self.makeBookmark(for: url) {
                        bookmarkData = bookmark
                        try? Self.writeConfiguration(NoteConfiguration(notePath: url.path, bookmark: bookmark), directory: directory)
                    }
                }
                usesManagedFile = false
            } else {
                self.fileURL = managed
                usesManagedFile = true
            }
            configurationError = nil
        } catch {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
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

    #if ISLAND_APP_STORE || ISLAND_TESTFLIGHT
    private static let usesSecurityScope = true
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    #else
    private static let usesSecurityScope = false
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    #endif

    /// Follow the open document when it was moved or renamed while Island Note runs.
    /// Returns true when the document now lives at a new path. Never creates,
    /// moves or rewrites the Markdown file itself.
    @discardableResult
    func relocateIfMoved() -> Bool {
        guard !usesManagedFile, configurationError == nil,
              !FileManager.default.fileExists(atPath: fileURL.path), let bookmarkData else { return false }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: Self.bookmarkResolutionOptions,
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
              resolved.standardizedFileURL != fileURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: resolved.path) else { return false }
        let previousState = syncStateURL(for: fileURL).deletingLastPathComponent()
        if Self.usesSecurityScope {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = resolved.startAccessingSecurityScopedResource() ? resolved : nil
        }
        fileURL = resolved
        let refreshed = (try? Self.makeBookmark(for: resolved)) ?? bookmarkData
        self.bookmarkData = refreshed
        try? Self.writeConfiguration(NoteConfiguration(notePath: resolved.path, bookmark: refreshed), directory: configurationDirectory)
        // Per-document sync state is keyed by path; carry it to the new location.
        let newState = syncStateURL(for: resolved).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: previousState.path), !FileManager.default.fileExists(atPath: newState.path) {
            try? FileManager.default.moveItem(at: previousState, to: newState)
        }
        NSLog("IslandNote: followed moved note to %@", resolved.path)
        return true
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
        let bookmark: Data? = try Self.makeBookmark(for: url)
        #else
        let bookmark: Data? = try? Self.makeBookmark(for: url)
        #endif
        try Self.writeConfiguration(NoteConfiguration(notePath: url.path, bookmark: bookmark), directory: configurationDirectory)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = accessed ? url : nil
        committed = true
        fileURL = url
        bookmarkData = bookmark
        usesManagedFile = false
        configurationError = nil
        lastLoadedContent = text
        lastErrorMessage = nil
        return text
    }

    /// Save a new copy and switch to it. Never truncate an existing destination.
    func saveCopyAndSwitch(to url: URL) throws -> String {
        guard flushSync(), let text = lastLoadedContent else { throw SaveError.documentNotLoaded }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        // Keep the copy if selection persistence fails. Legacy cloud records are
        // recovery data only; local file operations never read or rewrite them.
        return try openExisting(url)
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
    var modifiedAt: Date? {
        relocateIfMoved()
        var url = fileURL
        url.removeCachedResourceValue(forKey: .contentModificationDateKey)
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
    }

    private func createMissingFile(contents: String) throws {
        if usesManagedFile {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // For selected files, require the original folder to remain accessible.
        // Never reconstruct a moved folder or an unavailable external volume.
        try Data(contents.utf8).write(to: fileURL, options: .withoutOverwriting)
        NSLog("IslandNote: recreated missing note at %@", fileURL.path)
        if !usesManagedFile, let bookmark = try? Self.makeBookmark(for: fileURL) {
            bookmarkData = bookmark
            try? Self.writeConfiguration(NoteConfiguration(notePath: fileURL.path, bookmark: bookmark), directory: configurationDirectory)
        }
    }

    private func readOrCreate(contents: String) throws -> String {
        do { return try String(contentsOf: fileURL, encoding: .utf8) }
        catch {
            guard Self.isMissingFile(error) else { throw error }
            do { try createMissingFile(contents: contents) }
            catch CocoaError.fileWriteFileExists { /* Read a concurrently created file. */ }
            return try String(contentsOf: fileURL, encoding: .utf8)
        }
    }

    func load() throws -> String {
        if let configurationError { throw configurationError }
        relocateIfMoved()
        let text = try readOrCreate(contents: "")
        lastLoadedContent = text
        onSaveState?(.saved)
        return text
    }

    /// Pick up edits made in Obsidian when there is no unsaved Island Note text.
    func refreshIfClean() throws -> String? {
        guard pending == nil else { return nil }
        relocateIfMoved()
        if let configurationError { throw configurationError }
        let diskText = try readOrCreate(contents: lastLoadedContent ?? "")
        let changed = diskText != lastLoadedContent
        lastLoadedContent = diskText
        lastErrorMessage = nil
        onSaveState?(.saved)
        return changed ? diskText : nil
    }

    func save(_ text: String) {
        saveWork?.cancel()
        saveWork = nil
        if text == lastLoadedContent {
            pending = nil
            if lastErrorMessage == nil { onSaveState?(.saved) }
            return
        }
        pending = text
        onSaveState?(.saving)
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
            onSaveState?(.saved)
            onSaved?()
            onSyncNeeded?()
            return true
        } catch {
            let message = "Could not save to \(fileURL.path): \(error.localizedDescription)"
            lastErrorMessage = message
            NSLog("IslandNote: %@", message)
            onSaveState?(.failed(message))
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
        onSaveState?(.saved)
        onSaved?()
    }

    #endif

    private func coordinatedWrite(_ text: String, expected: String) throws {
        relocateIfMoved()
        if let configurationError { throw configurationError }
        do {
            _ = try fileURL.checkResourceIsReachable()
        } catch {
            guard Self.isMissingFile(error) else { throw error }
            try createMissingFile(contents: text)
            return
        }
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
