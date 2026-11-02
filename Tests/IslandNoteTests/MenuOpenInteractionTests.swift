import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class MenuOpenInteractionTests: XCTestCase {
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }

    func testMenuOpeningWaitsForAnimationThenNewOutsideMovement() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        try "Keep this text".write(to: note, atomically: true, encoding: .utf8)
        let previousMenu = NSApp.mainMenu
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = IslandNoteController(store: NoteStore(fileURL: note, configurationDirectory: directory),
            diagnostics: InteractionDiagnostics(defaults: nil, enabled: false))
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? IslandPanel }.first {
            !existing.contains(ObjectIdentifier($0))
        })
        defer { panel.close(); NSApp.mainMenu = previousMenu }

        func outsideMovement() throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: -100, y: -100),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        controller.openFromStatusMenu()
        // Keep the real cursor outside this test panel for the delayed collapse check.
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        controller.handleHover(try outsideMovement())
        controller.collapse(automatically: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(controller.mode, .expanded)
        wait(until: { !controller.isMenuOpening })

        // Stationary/non-motion callbacks cannot dismiss the now fully open note.
        controller.handleHover()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(controller.mode, .expanded)
        // Reopening an already expanded note must not leave a stale timer guard.
        controller.openFromStatusMenu()
        XCTAssertFalse(controller.isMenuOpening)
        controller.handleHover(try outsideMovement())
        wait(until: { controller.mode == .rest })
        XCTAssertEqual(try String(contentsOf: note), "Keep this text")
    }
}
