#if ISLAND_EVENT_PROBE
import AppKit

/// Only the dedicated probe build observes dispatch. It never changes an event.
@objc(IslandDiagnosticApplication)
final class IslandDiagnosticApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        EventDeliveryProbe.shared.observe(.application, event: event)
        super.sendEvent(event)
    }
}

@MainActor
final class EventDeliveryProbe {
    enum Stage: String, Codable { case application, monitor, consumed, handledForwarded, window, windowAfterDispatch, viewport, resizeFrame }
    struct NativeState: Codable {
        let allowsMagnification: Bool?
        let magnification: Double?
        let fontPointSize: Double?
    }
    struct Entry: Codable {
        let time: Date
        let uptime: Double
        let stage: Stage
        let eventType: UInt?
        let eventTimestamp: Double?
        let receiptCount: UInt64?
        let phase: UInt?
        let target: String?
        let delta: Double?
        let queueDelayMS: Double?
        let durationMS: Double?
        let windowMoveMS: Double?
        let layoutMS: Double?
        let viewportIntervalMS: Double?
        let nativeState: NativeState?
        let state: InteractionDiagnosticState
    }
    static let shared = EventDeliveryProbe()
    static let maximumEntries = 1200
    static let eventTypes: NSEvent.EventTypeMask = [.magnify, .rotate, .gesture, .beginGesture, .endGesture, .scrollWheel]
    var isEnabled: () -> Bool = { false }
    var state: (() -> InteractionDiagnosticState?)?
    private(set) var entries: [Entry] = []
    private var lastSample: [String: Double] = [:]
    private var receipts: [String: UInt64] = [:]
    private var lastFrame: Double?
    private var timer: Timer?
    private let directory: URL?
    private let writer = DispatchQueue(label: "local.projects.island-note.event-probe", qos: .utility)

    init(directory: URL? = nil) {
        self.directory = directory
    }

    func configure(isEnabled: @escaping () -> Bool, state: @escaping () -> InteractionDiagnosticState?) {
        self.isEnabled = isEnabled
        self.state = state
    }

    func observe(_ stage: Stage, event: NSEvent, nativeState: NativeState? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.eventTypes.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)),
              isEnabled() else { return }
        let hasPhase = [.magnify, .rotate, .scrollWheel].contains(event.type)
        let phase = hasPhase ? event.phase : []
        let lifecycle = phase.contains(.began) || phase.contains(.ended) || phase.contains(.cancelled)
            || event.type == .beginGesture || event.type == .endGesture
        let key = samplingKey(stage, event.type.rawValue)
        receipts[key, default: 0] += 1
        guard shouldSample(stage, event.type.rawValue, now: now, lifecycle: lifecycle),
              let snapshot = state?() else { return }
        let age = (now - event.timestamp) * 1000
        record(stage: stage, eventType: event.type.rawValue, eventTimestamp: event.timestamp,
            receiptCount: receipts[key], phase: hasPhase ? phase.rawValue : nil,
            target: event.window is IslandPanel ? "note" : event.window == nil ? "none" : "other",
            delta: event.type == .magnify ? finite(Double(event.magnification)) : nil,
            queueDelayMS: stage == .application && age >= 0 && age <= 600_000 ? finite(age) : nil,
            nativeState: nativeState, state: snapshot, now: now, lifecycle: lifecycle)
    }

    func viewport(started: Double, layoutEnded: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard isEnabled() else { return }
        let gap = lastFrame.map { (started - $0) * 1000 }
        lastFrame = started
        guard shouldSample(.viewport, nil, now: now, lifecycle: false), let snapshot = state?() else { return }
        record(stage: .viewport, durationMS: (now - started) * 1000,
            layoutMS: (layoutEnded - started) * 1000, viewportIntervalMS: gap,
            state: snapshot, now: now)
    }

    func endViewportSession() { lastFrame = nil }

    func resizeFrame(started: Double, windowMoved: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard isEnabled(), shouldSample(.resizeFrame, nil, now: now, lifecycle: false),
              let snapshot = state?() else { return }
        record(stage: .resizeFrame, durationMS: (now - started) * 1000,
            windowMoveMS: (windowMoved - started) * 1000, state: snapshot, now: now)
    }

    private func samplingKey(_ stage: Stage, _ type: UInt?) -> String {
        stage.rawValue + ":" + String(type ?? 0)
    }

    private func shouldSample(_ stage: Stage, _ type: UInt?, now: Double, lifecycle: Bool) -> Bool {
        if lifecycle { return true }
        return lastSample[samplingKey(stage, type)].map { now - $0 >= 0.1 } ?? true
    }

    // Explicit numeric allowlist. No text, file names, key events, or pointer positions.
    func record(stage: Stage, eventType: UInt? = nil, eventTimestamp: Double? = nil,
                receiptCount: UInt64? = nil, phase: UInt? = nil, target: String? = nil,
                delta: Double? = nil, queueDelayMS: Double? = nil, durationMS: Double? = nil,
                windowMoveMS: Double? = nil,
                layoutMS: Double? = nil, viewportIntervalMS: Double? = nil,
                nativeState: NativeState? = nil,
                state: InteractionDiagnosticState, now: Double, lifecycle: Bool = false) {
        guard isEnabled() else { return }
        let key = samplingKey(stage, eventType)
        guard shouldSample(stage, eventType, now: now, lifecycle: lifecycle) else { return }
        lastSample[key] = now
        entries.append(Entry(time: Date(), uptime: now, stage: stage, eventType: eventType,
            eventTimestamp: eventTimestamp.flatMap(finite), receiptCount: receiptCount,
            phase: phase, target: target, delta: delta.flatMap(finite),
            queueDelayMS: queueDelayMS.flatMap(finite), durationMS: durationMS.flatMap(finite),
            windowMoveMS: windowMoveMS.flatMap(finite),
            layoutMS: layoutMS.flatMap(finite), viewportIntervalMS: viewportIntervalMS.flatMap(finite),
            nativeState: nativeState.map { NativeState(allowsMagnification: $0.allowsMagnification,
                magnification: $0.magnification.flatMap(finite), fontPointSize: $0.fontPointSize.flatMap(finite)) }, state: state))
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer = nil; self?.persist() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

    func flush() {
        timer?.invalidate(); timer = nil
        persist()
        writer.sync {}
    }

    private var logDirectory: URL {
        directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IslandNote/Diagnostics", isDirectory: true)
    }

    func clear() {
        timer?.invalidate(); timer = nil
        writer.sync {}
        entries.removeAll()
        lastSample.removeAll()
        receipts.removeAll()
        lastFrame = nil
        let file = logDirectory.appendingPathComponent("delivery-events.jsonl")
        if FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) }
            catch { NSLog("Island Note event probe could not clear its local log.") }
        }
    }

    private func persist() {
        guard !entries.isEmpty else { return }
        let folder = logDirectory
        let snapshot = entries
        writer.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                var data = Data()
                for entry in snapshot { data.append(try encoder.encode(entry)); data.append(0x0a) }
                let file = folder.appendingPathComponent("delivery-events.jsonl")
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                NSLog("Island Note event probe could not write its local log.")
            }
        }
    }

    deinit { timer?.invalidate() }
}
#endif
