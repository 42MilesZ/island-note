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
}
