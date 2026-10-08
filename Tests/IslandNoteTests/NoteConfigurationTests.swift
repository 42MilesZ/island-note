import XCTest
@testable import IslandNote

final class NoteConfigurationTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testNewInstallCreatesOnlyManagedNote() throws {
        try fixture { directory in
            let store = NoteStore(configurationDirectory: directory)
            XCTAssertEqual(try store.load(), "")
            XCTAssertEqual(store.fileURL, directory.appendingPathComponent("Island Note.md"))
        }
    }

    func testPrivateConfigurationKeepsExistingNote() throws {
        try fixture { directory in
            let note = directory.appendingPathComponent("existing.md")
            try "Existing text".write(to: note, atomically: true, encoding: .utf8)
            let settings = try JSONSerialization.data(withJSONObject: ["notePath": note.path])
            try settings.write(to: directory.appendingPathComponent("settings.json"))
            let store = NoteStore(configurationDirectory: directory)
            XCTAssertEqual(try store.load(), "Existing text")
            XCTAssertEqual(store.fileURL, note)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Island Note.md").path))
        }
    }

    func testInvalidConfigurationCannotCreateOrOverwriteFallback() throws {
        try fixture { directory in
            try "invalid json".write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            let store = NoteStore(configurationDirectory: directory)
            XCTAssertThrowsError(try store.load())
            store.save("Should not save")
            XCTAssertFalse(store.flushSync())
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Island Note.md").path))
        }
    }

    func testOpenExistingPersistsSelectionAndKeepsBothFiles() throws {
        try fixture { directory in
            let store = NoteStore(configurationDirectory: directory)
            _ = try store.load()
            let old = store.fileURL
            store.save("Original")
            let chosen = directory.appendingPathComponent("chosen.md")
            try "Existing".write(to: chosen, atomically: true, encoding: .utf8)
            XCTAssertEqual(try store.openExisting(chosen), "Existing")
            store.save("Edited existing")
            XCTAssertTrue(store.flushSync())
            XCTAssertEqual(try String(contentsOf: old), "Original")
            XCTAssertEqual(try NoteStore(configurationDirectory: directory).load(), "Edited existing")
        }
    }

    func testSaveCopyKeepsOriginalAndCannotOverwriteExistingDestination() throws {
        try fixture { directory in
            let store = NoteStore(configurationDirectory: directory)
            _ = try store.load()
            let old = store.fileURL
            store.save("Unsaved typing")
            let copy = directory.appendingPathComponent("copy.md")
            XCTAssertEqual(try store.saveCopyAndSwitch(to: copy), "Unsaved typing")
            XCTAssertEqual(try String(contentsOf: old), "Unsaved typing")
            let existing = directory.appendingPathComponent("other.md")
            try "Do not replace".write(to: existing, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.saveCopyAndSwitch(to: existing))
            XCTAssertEqual(store.fileURL, copy)
            XCTAssertEqual(try String(contentsOf: existing), "Do not replace")
        }
    }

    func testSaveLocationChangeKeepsTheSameConnectionWithoutReplacingAnother() throws {
        try fixture { directory in
            let store = NoteStore(configurationDirectory: directory)
            _ = try store.load()
            let original = store.fileURL
            let record = SyncRecord(enabled: true, memoID: "original", baseline: "Base", pendingWrite: "Pending")
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("flomo-sync.json"))
            try store.prepareSyncState()
            let originalState = store.syncStateURL
            let copy = directory.appendingPathComponent("relocated.md")
            _ = try store.saveCopyAndSwitch(to: copy)
            let relocated = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: store.syncStateURL))
            XCTAssertEqual(relocated, record)
            let paused = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: originalState))
            XCTAssertFalse(paused.enabled)
            XCTAssertEqual(paused.memoID, record.memoID)
            XCTAssertEqual(paused.pendingWrite, record.pendingWrite)
            let copiedState = store.syncStateURL
            _ = try store.openExisting(original)
            try FileManager.default.removeItem(at: copy) // Own disposable fixture only.
            XCTAssertThrowsError(try store.saveCopyAndSwitch(to: copy))
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertEqual(store.fileURL, original)
            XCTAssertEqual(try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: copiedState)), record)
        }
    }

    func testSaveLocationConfigurationFailureRestoresOnlyOriginalActiveConnection() throws {
        try fixture { directory in
            let store = NoteStore(configurationDirectory: directory)
            _ = try store.load()
            let original = store.fileURL
            let record = SyncRecord(enabled: true, memoID: "original", pendingWrite: "Pending")
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("flomo-sync.json"))
            try store.prepareSyncState()
            let originalState = store.syncStateURL
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("settings.json"), withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent("copy.md")
            let targetState = NoteStore(fileURL: copy, configurationDirectory: directory).syncStateURL
            XCTAssertThrowsError(try store.saveCopyAndSwitch(to: copy))
            XCTAssertEqual(store.fileURL, original)
            XCTAssertEqual(try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: originalState)), record)
            XCTAssertFalse(FileManager.default.fileExists(atPath: targetState.path))
            XCTAssertEqual(try String(contentsOf: copy), "")
        }
    }

    func testUnreadableSelectionAndExternalConflictKeepCurrentDocument() throws {
        try fixture { directory in
            let store = NoteStore(configurationDirectory: directory)
            _ = try store.load()
            let old = store.fileURL
            XCTAssertThrowsError(try store.openExisting(directory.appendingPathComponent("missing.md")))
            XCTAssertEqual(store.fileURL, old)
            try "Outside edit".write(to: old, atomically: true, encoding: .utf8)
            store.save("Pending local edit")
            let other = directory.appendingPathComponent("other.md")
            try "Other".write(to: other, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.openExisting(other))
            XCTAssertEqual(store.fileURL, old)
            XCTAssertEqual(try String(contentsOf: old), "Outside edit")
            XCTAssertFalse(store.flushSync())
        }
    }

    func testLegacyConnectionBelongsOnlyToOriginalFileAndReturnsOnReopen() throws {
        try fixture { directory in
            let store = NoteStore(configurationDirectory: directory)
            _ = try store.load()
            let original = store.fileURL
            let legacy = directory.appendingPathComponent("flomo-sync.json")
            try JSONEncoder().encode(SyncRecord(enabled: true, memoID: "old-memo", baseline: "Base")).write(to: legacy)
            try store.prepareSyncState()
            let originalSync = store.syncStateURL
            XCTAssertEqual(try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: originalSync)).memoID, "old-memo")
            let other = directory.appendingPathComponent("other.md")
            try "Other".write(to: other, atomically: true, encoding: .utf8)
            _ = try store.openExisting(other)
            try store.prepareSyncState()
            XCTAssertNotEqual(store.syncStateURL, originalSync)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.syncStateURL.path))
            let reopened = NoteStore(configurationDirectory: directory)
            _ = try reopened.load()
            try reopened.prepareSyncState()
            XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.syncStateURL.path))
            _ = try reopened.openExisting(original)
            XCTAssertEqual(reopened.syncStateURL, originalSync)
            XCTAssertEqual(try Data(contentsOf: legacy), try Data(contentsOf: originalSync))
        }
    }

    func testImportRequiresMatchingFileKeepsWriteIntentAndStartsPaused() throws {
        try fixture { directory in
            let previous = directory.appendingPathComponent("previous")
            let current = directory.appendingPathComponent("current")
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            let note = directory.appendingPathComponent("original.md")
            try "Original".write(to: note, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: ["notePath": note.path]).write(to: previous.appendingPathComponent("settings.json"))
            let record = SyncRecord(enabled: true, memoID: "old-memo", baseline: "Base", pendingWrite: "Pending")
            let originalData = try JSONEncoder().encode(record)
            try originalData.write(to: previous.appendingPathComponent("flomo-sync.json"))
            let store = NoteStore(configurationDirectory: current)
            _ = try store.load()
            XCTAssertThrowsError(try store.importPreviousConnection(from: previous))
            _ = try store.openExisting(note)
            try store.importPreviousConnection(from: previous)
            let imported = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: store.syncStateURL))
            XCTAssertFalse(imported.enabled)
            XCTAssertEqual(imported.memoID, record.memoID)
            XCTAssertEqual(imported.pendingWrite, record.pendingWrite)
            XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("flomo-sync.json")), originalData)
            XCTAssertThrowsError(try store.importPreviousConnection(from: previous))
        }
    }

    func testDefaultLegacyNoteRestoresUncertainCreationWithoutSettingsFile() throws {
        try fixture { directory in
            let previous = directory.appendingPathComponent("previous")
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            let note = previous.appendingPathComponent("Island Note.md")
            try "Original".write(to: note, atomically: true, encoding: .utf8)
            let record = SyncRecord(enabled: true, pendingWrite: "Awaiting ID", creationUncertain: true)
            try JSONEncoder().encode(record).write(to: previous.appendingPathComponent("flomo-sync.json"))
            let store = NoteStore(fileURL: note, configurationDirectory: directory.appendingPathComponent("current"))
            _ = try store.load()
            try store.importPreviousConnection(from: previous)
            let restored = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: store.syncStateURL))
            XCTAssertTrue(restored.creationUncertain)
            XCTAssertEqual(restored.pendingWrite, "Awaiting ID")
            XCTAssertNil(restored.memoID)
            XCTAssertFalse(restored.enabled)
        }
    }
}
