import AppKit
import OSLog

enum InteractionDiagnosticReason: String, Codable {
    case enabled, disabled, checkpoint, pinchReceived, wrongWindow
    case panelClosed, outsidePanel, headerDragging, edgeResizing
    case belowThreshold, gestureAlreadyHandled, presetLimit, sizeLimit
    case gestureCancelled, invalidGesture, resizeRequested, resizeQueued
    case resizeCompleted, resizeInterrupted, resizeStalled
    case headerGrabbed, headerReleased, floatingChanged, edgeResizeBegan, edgeResizeEnded
    case gestureFinished, gestureInterrupted, noGestureEvents
    case continuousResizeBegan, continuousResizeFinished
    case resizeHoverChanged

    var explanation: String {
        switch self {
        case .enabled: return L10n.tr("Local diagnostics are on.")
        case .disabled: return L10n.tr("Local diagnostics are off. No new events are recorded.")
        case .wrongWindow: return L10n.tr("The resize event was not delivered to the note panel.")
        case .panelClosed: return L10n.tr("The panel was collapsed, so resizing was not performed.")
        case .outsidePanel: return L10n.tr("The gesture started outside the panel.")
        case .headerDragging: return L10n.tr("The drag strip owns the interaction, so pinch resizing is paused.")
        case .edgeResizing: return L10n.tr("An edge resize owns the interaction, so pinch resizing is paused.")
        case .belowThreshold: return L10n.tr("The legacy resize threshold was not reached.")
        case .gestureAlreadyHandled: return L10n.tr("The legacy gesture had already been handled.")
        case .presetLimit: return L10n.tr("The legacy preset limit was reached.")
        case .sizeLimit: return L10n.tr("The screen or panel size limit was reached.")
        case .gestureCancelled: return L10n.tr("The system cancelled the gesture.")
        case .invalidGesture: return L10n.tr("The system provided an invalid magnification value.")
        case .resizeRequested: return L10n.tr("Resizing was accepted and started.")
        case .resizeQueued: return L10n.tr("The panel is docking; resizing is queued until arrival.")
        case .resizeCompleted: return L10n.tr("The resize animation reached its target.")
        case .resizeInterrupted: return L10n.tr("A new interaction interrupted the resize animation.")
        case .resizeStalled: return L10n.tr("Possible issue: the resize animation ended without reaching its target.")
        case .gestureInterrupted: return L10n.tr("A new gesture reset the previous unfinished gesture.")
        case .noGestureEvents: return L10n.tr("No resize events were received in the last minute. Check gesture delivery or the time of the issue.")
        case .continuousResizeBegan: return L10n.tr("The panel started continuous pinch resizing.")
        case .continuousResizeFinished: return L10n.tr("Continuous resizing ended; the size was retained for this layout.")
        case .resizeHoverChanged: return L10n.tr("The pointer entered, left or changed the resize area, recorded in resizeHoverEdges.")
        default: return L10n.tr("The interaction state was recorded.")
        }
    }
}

/// Explicit allowlist: no note text, file names, credentials, screenshots or global pointer positions.
struct InteractionDiagnosticState: Codable {
    var mode: String
    var floating: Bool
    var dragging: Bool
    var docking: Bool
    var edgeResizing: Bool
    var animating: Bool
    var panelKey: Bool
    var appActive: Bool
    var reduceMotion: Bool
    var width: Double
    var height: Double
    var targetWidth: Double?
    var targetHeight: Double?
    var screenWidth: Double
    var screenHeight: Double
    var resizeHoverEdges: Int? = nil
}

struct InteractionDiagnosticEvent: Codable {
    let time: Date
    let reason: InteractionDiagnosticReason
    let state: InteractionDiagnosticState
    let delta: Double?
    let phase: UInt?
}

/// Opt-in, bounded local recorder. Disk writes are batched and happen off the UI thread.
@MainActor
final class InteractionDiagnostics {
    static let shared = InteractionDiagnostics()
    static let preferenceKey = "localInteractionDiagnosticsEnabled"
    static let maximumEvents = 300
    private(set) var isEnabled: Bool
    private(set) var events: [InteractionDiagnosticEvent] = []
    private let directory: URL?
    private let defaults: UserDefaults?
    private let writer = DispatchQueue(label: "local.projects.island-note.interaction-diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "local.projects.island-note", category: "Diagnostics")
    private var saveTimer: Timer?
    private var lastPinchReceipt = Date.distantPast
    var reportURL: URL? { directory?.appendingPathComponent("latest-report.md") }

    init(directory: URL? = nil, defaults: UserDefaults? = .standard, enabled: Bool? = nil) {
        self.directory = directory ?? (defaults == nil ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("IslandNote/Diagnostics", isDirectory: true))
        self.defaults = defaults
        isEnabled = enabled ?? defaults?.bool(forKey: Self.preferenceKey) ?? false
        if isEnabled { reloadHistoryIfEmpty() }
    }

    func setEnabled(_ enabled: Bool, state: InteractionDiagnosticState) {
        guard enabled != isEnabled else { return }
        if !enabled {
            record(.disabled, state: state)
            saveTimer?.invalidate(); saveTimer = nil
            persist()
        }
        isEnabled = enabled
        defaults?.set(enabled, forKey: Self.preferenceKey)
        if enabled { reloadHistoryIfEmpty(); record(.enabled, state: state) }
    }

    func record(_ reason: InteractionDiagnosticReason, state: InteractionDiagnosticState,
                delta: CGFloat? = nil, phase: NSEvent.Phase? = nil) {
        guard isEnabled else { return }
        // Sample high-frequency changed events; lifecycle and decisions are never dropped.
        if reason == .pinchReceived, phase == .changed {
            guard Date().timeIntervalSince(lastPinchReceipt) >= 0.1 else { return }
        }
        if reason == .pinchReceived { lastPinchReceipt = Date() }
        events.append(InteractionDiagnosticEvent(time: Date(), reason: reason, state: state,
            delta: delta.flatMap { $0.isFinite ? Double($0) : nil }, phase: phase?.rawValue))
        if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
        guard saveTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTimer = nil; self?.persist() }
        }
        saveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func markProblem(state: InteractionDiagnosticState) {
        let recentPinch = events.contains { $0.reason == .pinchReceived && Date().timeIntervalSince($0.time) < 60 }
        record(recentPinch ? .checkpoint : .noGestureEvents, state: state)
        flush()
    }

    var report: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let evidence = events.filter { ![.pinchReceived, .gestureAlreadyHandled, .gestureFinished, .headerGrabbed, .headerReleased, .checkpoint].contains($0.reason) }.suffix(12)
        var lines = ["# Island Note · " + L10n.tr("Local Diagnostic Report"), "", L10n.format("Version: %@ (%@); diagnostic format: 1", version, build), L10n.tr("System: ") + ProcessInfo.processInfo.operatingSystemVersionString,
                     L10n.tr("Generated: ") + Date().ISO8601Format(), "", L10n.tr("Saved locally, without note text, file names, accounts or screenshots. Gesture deltas are sampled at most every 0.1 seconds; phases and decisions are retained."), "",
                     L10n.tr("## Automatic Findings"), "", L10n.tr("These findings use interaction rules and may not identify every cause.")]
        if evidence.isEmpty { lines.append(L10n.tr("No interaction events are available. Turn on diagnostics, reproduce the problem, then export a report.")) }
        for event in evidence { lines.append("- \(event.time.ISO8601Format()) · \(event.reason.explanation)") }
        lines += ["", L10n.tr("## Recent Interactions"), "", L10n.tr("| Time | State | Panel Size | Floating / Dragging / Docking / Animating |"), "| --- | --- | --- | --- |"]
        for event in events.suffix(40) {
            let s = event.state
            lines.append("| \(event.time.ISO8601Format()) | \(event.reason.rawValue) | \(Int(s.width)) × \(Int(s.height)) | \(s.floating) / \(s.dragging) / \(s.docking) / \(s.animating) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var recentFindings: String {
        events.filter { ![.pinchReceived, .gestureAlreadyHandled, .gestureFinished, .checkpoint, .headerGrabbed, .headerReleased].contains($0.reason) }
            .suffix(5).map { $0.reason.explanation }.joined(separator: "\n")
    }

    func reloadHistoryIfEmpty() {
        guard events.isEmpty, let directory else { return }
        let url = directory.appendingPathComponent("events.jsonl")
        // Refuse unexpectedly large files; normal output is bounded to 300 records.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = data.split(separator: 0x0a).suffix(Self.maximumEvents).compactMap {
            guard let event = try? decoder.decode(InteractionDiagnosticEvent.self, from: Data($0)),
                  ["rest", "hover", "expanded"].contains(event.state.mode),
                  event.state.width.isFinite, event.state.height.isFinite,
                  (0...100_000).contains(event.state.width), (0...100_000).contains(event.state.height) else { return nil }
            return event
        }
    }

    func clear() {
        saveTimer?.invalidate(); saveTimer = nil
        writer.sync {}
        events.removeAll()
        lastPinchReceipt = .distantPast
        guard let directory else { return }
        for name in ["events.jsonl", "latest-report.md"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { logger.error("Diagnostic clear failed: \(error.localizedDescription, privacy: .private)") }
            }
        }
    }

    func flush() {
        saveTimer?.invalidate(); saveTimer = nil
        persist()
        writer.sync {}
    }

    private func persist() {
        guard let directory, !events.isEmpty else { return }
        let snapshot = events
        let report = self.report
        let logger = self.logger
        writer.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var data = Data()
                for event in snapshot { data.append(try encoder.encode(event)); data.append(0x0a) }
                let logURL = directory.appendingPathComponent("events.jsonl")
                let reportURL = directory.appendingPathComponent("latest-report.md")
                try data.write(to: logURL, options: .atomic)
                try Data(report.utf8).write(to: reportURL, options: .atomic)
                for url in [logURL, reportURL] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            } catch {
                logger.error("Local diagnostic write failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    deinit { saveTimer?.invalidate() }
}
