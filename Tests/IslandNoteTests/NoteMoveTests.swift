import XCTest
@testable import IslandNote

/// Moving or renaming the note (or its folder) must never lock the editor,
/// lose typing, or recreate a moved file at its old path.
final class NoteMoveTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-move-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeNote(in directory: URL, folder: String, text: String) throws -> URL {
        let folderURL = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let note = folderURL.appendingPathComponent("Island Note.md")
        try text.write(to: note, atomically: true, encoding: .utf8)
        return note
    }

    func testRenamedFolderWhileRunningIsFollowedAndSaved() throws {
        try fixture { directory in
            let config = directory.appendingPathComponent("config")
            let note = try makeNote(in: directory, folder: "Dairy notes", text: "Before")
            let store = NoteStore(configurationDirectory: config)
            XCTAssertEqual(try store.openExisting(note), "Before")
            let moved = directory.appendingPathComponent("Diary notes")
            try FileManager.default.moveItem(at: note.deletingLastPathComponent(), to: moved)
            XCTAssertNil(try store.refreshIfClean())
            XCTAssertEqual(store.fileURL.lastPathComponent, "Island Note.md")
            XCTAssertEqual(store.fileURL.deletingLastPathComponent().lastPathComponent, "Diary notes")
            store.save("After move")
            XCTAssertTrue(store.flushSync())
            XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("Island Note.md")), "After move")
            XCTAssertFalse(FileManager.default.fileExists(atPath: note.deletingLastPathComponent().path))
            // A relaunch opens the new location.
            XCTAssertEqual(try NoteStore(configurationDirectory: config).load(), "After move")
        }
    }

    func testMovedFileWithPendingTypingSavesToNewLocation() throws {
        try fixture { directory in
            let config = directory.appendingPathComponent("config")
            let note = try makeNote(in: directory, folder: "A", text: "One")
            let store = NoteStore(configurationDirectory: config)
            _ = try store.openExisting(note)
            store.save("Typed before move")
            let target = try makeNote(in: directory, folder: "B", text: "placeholder")
            try FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: note, to: target)
            XCTAssertTrue(store.flushSync())
            XCTAssertEqual(try String(contentsOf: target), "Typed before move")
            XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        }
    }

    func testLegacyPathOnlySettingsAreUpgradedSoLaterMovesAreFollowed() throws {
        try fixture { directory in
            let config = directory.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let note = try makeNote(in: directory, folder: "Old", text: "Legacy")
            let settings = try JSONSerialization.data(withJSONObject: ["notePath": note.path])
            try settings.write(to: config.appendingPathComponent("settings.json"))
            _ = try NoteStore(configurationDirectory: config).load()
            let renamed = directory.appendingPathComponent("New")
            try FileManager.default.moveItem(at: note.deletingLastPathComponent(), to: renamed)
            XCTAssertEqual(try NoteStore(configurationDirectory: config).load(), "Legacy")
        }
    }

    func testDeletedNoteIsRecreatedWithPendingText() throws {
        try fixture { directory in
            let config = directory.appendingPathComponent("config")
            let note = try makeNote(in: directory, folder: "A", text: "Gone")
            let store = NoteStore(configurationDirectory: config)
            _ = try store.openExisting(note)
            try FileManager.default.removeItem(at: note)
            store.save("Unsaved")
            XCTAssertTrue(store.flushSync())
            XCTAssertEqual(try String(contentsOf: note), "Unsaved")
            XCTAssertNil(store.lastErrorMessage)
        }
    }

    func testMissingPathOnlyNoteIsCreatedWithoutResettingSelection() throws {
        try fixture { directory in
            let missing = directory.appendingPathComponent("custom.md")
            try JSONSerialization.data(withJSONObject: ["notePath": missing.path])
                .write(to: directory.appendingPathComponent("settings.json"))
            let store = NoteStore(configurationDirectory: directory)
            XCTAssertEqual(try store.load(), "")
            XCTAssertEqual(store.fileURL, missing)
            store.save("New note")
            XCTAssertTrue(store.flushSync())
            let reopened = NoteStore(configurationDirectory: directory)
            XCTAssertEqual(try reopened.load(), "New note")
            XCTAssertEqual(reopened.fileURL.resolvingSymlinksInPath(), missing.resolvingSymlinksInPath())
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Island Note.md").path))
        }
    }

    func testDeletedBookmarkedNoteIsRecreatedAfterRelaunch() throws {
        try fixture { directory in
            let note = try makeNote(in: directory, folder: "Notes", text: "Old")
            let config = directory.appendingPathComponent("config")
            let store = NoteStore(configurationDirectory: config)
            _ = try store.openExisting(note)
            try FileManager.default.removeItem(at: note)
            let reopened = NoteStore(configurationDirectory: config)
            XCTAssertEqual(try reopened.load(), "")
            XCTAssertEqual(reopened.fileURL, note)
            reopened.save("Recreated")
            XCTAssertTrue(reopened.flushSync())
            XCTAssertEqual(try NoteStore(configurationDirectory: config).load(), "Recreated")
        }
    }

    func testRefreshRecreatesDeletedNoteWithLoadedContents() throws {
        try fixture { directory in
            let note = try makeNote(in: directory, folder: "Notes", text: "Keep me")
            let store = NoteStore(configurationDirectory: directory.appendingPathComponent("config"))
            _ = try store.openExisting(note)
            try FileManager.default.removeItem(at: note)
            XCTAssertNil(try store.refreshIfClean())
            XCTAssertEqual(try String(contentsOf: note), "Keep me")
        }
    }

    func testMissingSelectedFolderDoesNotResetPathOrRecreateFolder() throws {
        try fixture { directory in
            let missing = directory.appendingPathComponent("Unavailable/note.md")
            let settings = directory.appendingPathComponent("settings.json")
            let data = try JSONSerialization.data(withJSONObject: ["notePath": missing.path])
            try data.write(to: settings)
            let store = NoteStore(configurationDirectory: directory)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(store.fileURL, missing)
            XCTAssertEqual(try Data(contentsOf: settings), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        }
    }
}
