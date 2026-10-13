#if ISLAND_EVENT_PROBE
import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class EventDeliveryProbeTests: XCTestCase {
    private let state = InteractionDiagnosticState(mode: "expanded", floating: true, dragging: false,
        docking: false, edgeResizing: false, animating: false, panelKey: true, appActive: true,
        reduceMotion: false, width: 420, height: 460, targetWidth: nil, targetHeight: nil,
        screenWidth: 1500, screenHeight: 900)

    func testOptInSamplingKeepsSeparateStagesAndLifecycle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("event-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = EventDeliveryProbe(directory: folder)
        probe.record(stage: .application, eventType: NSEvent.EventType.magnify.rawValue, state: state, now: 1)
        XCTAssertTrue(probe.entries.isEmpty)
        probe.isEnabled = { true }
        for stage in [EventDeliveryProbe.Stage.application, .monitor, .consumed] {
            probe.record(stage: stage, eventType: NSEvent.EventType.magnify.rawValue, state: state, now: 1)
            probe.record(stage: stage, eventType: NSEvent.EventType.magnify.rawValue, state: state, now: 1.01)
            probe.record(stage: stage, eventType: NSEvent.EventType.magnify.rawValue,
                phase: NSEvent.Phase.ended.rawValue, state: state, now: 1.02, lifecycle: true)
        }
        XCTAssertEqual(probe.entries.count, 6)
        XCTAssertEqual(probe.entries.filter { $0.phase == NSEvent.Phase.ended.rawValue }.count, 3)
        probe.flush()
        let file = folder.appendingPathComponent("delivery-events.jsonl")
        let first = try XCTUnwrap(Data(contentsOf: file).split(separator: 0x0a).first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["time", "uptime", "stage", "eventType", "state"]))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testBoundedNumericLogRejectsNonFiniteMeasurements() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("event-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = EventDeliveryProbe(directory: folder)
        probe.isEnabled = { true }
        for i in 0..<(EventDeliveryProbe.maximumEntries + 20) {
            probe.record(stage: .viewport, durationMS: .infinity, layoutMS: .nan,
                state: state, now: Double(i), lifecycle: true)
        }
        XCTAssertEqual(probe.entries.count, EventDeliveryProbe.maximumEntries)
        XCTAssertNil(probe.entries.last?.durationMS)
        XCTAssertNil(probe.entries.last?.layoutMS)
        probe.flush()
    }

    func testClearRemovesPendingAndPersistedRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("event-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = EventDeliveryProbe(directory: folder)
        probe.isEnabled = { true }
        probe.record(stage: .application, state: state, now: 1)
        probe.flush()
        let file = folder.appendingPathComponent("delivery-events.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        probe.record(stage: .monitor, state: state, now: 2)
        probe.clear()
        probe.flush()
        XCTAssertTrue(probe.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
