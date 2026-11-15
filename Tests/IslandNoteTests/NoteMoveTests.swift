import XCTest
@testable import IslandNote

/// Moving or renaming the note (or its folder) must never lock the editor,
/// lose typing, or recreate the file at its old path.
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

    func testDeletedNoteIsNotRecreatedAtOldPath() throws {
        try fixture { directory in
            let config = directory.appendingPathComponent("config")
            let note = try makeNote(in: directory, folder: "A", text: "Gone")
            let store = NoteStore(configurationDirectory: config)
            _ = try store.openExisting(note)
            try FileManager.default.removeItem(at: note)
            store.save("Unsaved")
            XCTAssertFalse(store.flushSync())
            XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
            XCTAssertNotNil(store.lastErrorMessage)
        }
    }

    func testMissingPathOnlyNoteReportsHowToReselect() throws {
        try fixture { directory in
            let config = directory.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let missing = directory.appendingPathComponent("Dairy notes/Island Note.md")
            let settings = try JSONSerialization.data(withJSONObject: ["notePath": missing.path])
            try settings.write(to: config.appendingPathComponent("settings.json"))
            let store = NoteStore(configurationDirectory: config)
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertTrue(error.localizedDescription.contains("Open Existing File"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.appendingPathComponent("Island Note.md").path))
        }
    }
}
