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
        case .enabled: return "本机诊断已开启。"
        case .disabled: return "本机诊断已关闭，停止收集新事件。"
        case .wrongWindow: return "缩放事件没有投递到笔记面板。"
        case .panelClosed: return "面板处于收起状态，未执行缩放。"
        case .outsidePanel: return "手势起点位于面板外，未接管缩放。"
        case .headerDragging: return "正在按住拖拽栏，此时不执行双指缩放。"
        case .edgeResizing: return "正在拖动边缘，此时不执行双指缩放。"
        case .belowThreshold: return "本次缩放幅度尚未达到触发阈值。"
        case .gestureAlreadyHandled: return "这一轮手势已处理过，抬起手指后可开始下一轮。"
        case .presetLimit: return "已到当前预设的最大或最小档位。"
        case .sizeLimit: return "尺寸已到屏幕或面板的上下限。"
        case .gestureCancelled: return "系统取消了这轮手势。"
        case .invalidGesture: return "系统提供了无效的缩放数值。"
        case .resizeRequested: return "已接收缩放并开始调整尺寸。"
        case .resizeQueued: return "正在吸附回岛，缩放将在回岛后执行。"
        case .resizeCompleted: return "尺寸动画已完成，实际尺寸到达目标。"
        case .resizeInterrupted: return "尺寸动画被新的交互打断。"
        case .resizeStalled: return "疑似异常：动画结束后的尺寸没有到达目标。"
        case .gestureInterrupted: return "上一轮手势没有收到结束事件，已由新手势重置。"
        case .noGestureEvents: return "最近一分钟未收到缩放事件，需要检查系统手势投递或确认问题发生的时间。"
        case .continuousResizeBegan: return "面板开始随双指幅度连续调整尺寸。"
        case .continuousResizeFinished: return "连续缩放结束，已保留对应状态的尺寸。"
        case .resizeHoverChanged: return "指针进入、离开或切换了缩放提示区；区域记录在 resizeHoverEdges 中。"
        default: return "已记录交互状态。"
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
        var lines = ["# Island Note 本机交互诊断", "", "版本：\(version) (\(build))；交互诊断格式：1", "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "生成时间：\(Date().ISO8601Format())", "", "仅保存在本机，未上传。无笔记正文、文件名、账号或截图。高频手势增量最多每 0.1 秒采样一次；阶段变化与处理决定保留。", "",
                     "## 自动判断", "", "以下是交互状态的规则判断，不代表已经确认所有 bug 的根因。"]
        if evidence.isEmpty { lines.append("尚无可分析的交互事件。开启诊断后重现问题，再记录一次异常。") }
        for event in evidence { lines.append("- \(event.time.ISO8601Format()) · \(event.reason.explanation)") }
        lines += ["", "## 最近交互", "", "| 时间 | 状态 | 面板尺寸 | 浮动 / 拖拽 / 回岛 / 动画 |", "| --- | --- | --- | --- |"]
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
