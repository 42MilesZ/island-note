import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class InteractionDiagnosticsTests: XCTestCase {
    private let state = InteractionDiagnosticState(mode: "expanded", floating: true, dragging: false,
        docking: false, edgeResizing: false, animating: false, panelKey: true, appActive: true,
        reduceMotion: false, width: 420, height: 460, targetWidth: nil, targetHeight: nil,
        screenWidth: 1500, screenHeight: 900)

    func testOptInBoundedPersistenceSurvivesRestartAndDisabling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-diagnostics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = InteractionDiagnostics(directory: directory, defaults: nil, enabled: false)
        diagnostics.record(.pinchReceived, state: state)
        diagnostics.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        diagnostics.setEnabled(true, state: state)
        for _ in 0..<400 { diagnostics.record(.pinchReceived, state: state, delta: 0.01, phase: .began) }
        diagnostics.record(.outsidePanel, state: state)
        diagnostics.markProblem(state: state)
        diagnostics.setEnabled(false, state: state)
        diagnostics.flush()
        let url = directory.appendingPathComponent("events.jsonl")
        let before = try Data(contentsOf: url)
        XCTAssertEqual(diagnostics.events.count, InteractionDiagnostics.maximumEvents)
        diagnostics.record(.headerGrabbed, state: state)
        diagnostics.flush()
        XCTAssertEqual(try Data(contentsOf: url), before)
        let restarted = InteractionDiagnostics(directory: directory, defaults: nil, enabled: true)
        XCTAssertEqual(restarted.events.count, InteractionDiagnostics.maximumEvents)
        XCTAssertEqual(restarted.events.last?.reason, .disabled)
        XCTAssertTrue(restarted.report.contains(InteractionDiagnosticReason.outsidePanel.explanation))
        let lines = before.split(separator: 0x0a)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["time", "reason", "state", "delta", "phase"]))
        let recordedState = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertFalse(recordedState.keys.contains(where: { ["text", "path", "token", "screenshot", "x", "y"].contains($0) }))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testProblemWithoutGestureEventsAndInvalidDeltaAreExplained() {
        let diagnostics = InteractionDiagnostics(defaults: nil, enabled: true)
        diagnostics.markProblem(state: state)
        XCTAssertEqual(diagnostics.events.last?.reason, .noGestureEvents)
        diagnostics.record(.pinchReceived, state: state, delta: .nan, phase: .began)
        diagnostics.record(.invalidGesture, state: state, delta: .infinity, phase: .changed)
        XCTAssertNil(diagnostics.events.last?.delta)
        diagnostics.markProblem(state: state)
        XCTAssertEqual(diagnostics.events.last?.reason, .checkpoint)
        XCTAssertTrue(diagnostics.report.contains(InteractionDiagnosticReason.invalidGesture.explanation))
        diagnostics.record(.resizeStalled, state: state)
        XCTAssertTrue(diagnostics.recentFindings.contains("疑似异常"))
    }

    func testUnexpectedlyLargeHistoryIsNotLoadedOrModified() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-large-diagnostics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let data = Data(repeating: 0x20, count: 512_001)
        try data.write(to: url)
        let diagnostics = InteractionDiagnostics(directory: directory, defaults: nil, enabled: true)
        XCTAssertTrue(diagnostics.events.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
