import Foundation
import OSLog

struct SyncRecord: Codable, Equatable {
    var enabled = false
    var memoID: String?
    var baseline: String?
    var pendingWrite: String?
    var creationUncertain = false
}

enum SyncChoice { case local, remote }

struct SyncConflict {
    let local: String
    let remote: FlomoMemo
}

enum SyncDirection: Equatable { case none, push, pull, conflict }

enum SyncComparison {
    static func direction(baseline: String?, local: String, remote: String) -> SyncDirection {
        if local == remote { return .none }
        guard let baseline else { return .conflict }
        if local == baseline { return .pull }
        if remote == baseline { return .push }
        return .conflict
    }
}

@MainActor
final class FlomoSync {
    private(set) var record: SyncRecord
    private(set) var status = "Flomo not connected"
    private(set) var conflict: SyncConflict?
    var onStatus: ((String, Bool) -> Void)?
    /// Must flush pending editor changes and read the current file each time.
    var readLocal: (() throws -> String)?
    /// Compare the editor/file against expected before applying; save a backup.
    var applyRemote: ((_ expected: String, _ replacement: String) throws -> Void)?
    private let stateURL: URL
    private var client: FlomoServing?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var running = false
    private var generation = UUID()
    private let logger = Logger(subsystem: "local.projects.island-note", category: "FlomoSync")

    init(stateURL: URL) throws {
        self.stateURL = stateURL
        if FileManager.default.fileExists(atPath: stateURL.path) {
            record = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: stateURL))
        } else { record = SyncRecord() }
    }

    func start(client: FlomoServing) {
        self.client = client
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.request() }
        }
        if record.enabled { request() }
        else { report("Flomo sync paused") }
    }

    func connect(client: FlomoServing, memoID: String?) async {
        guard !running else { report("Wait for the current sync to finish", error: true); return }
        guard !record.creationUncertain || memoID != nil else {
            report("A note may already exist. Enter its Flomo URL before reconnecting.", error: true); return
        }
        generation = UUID()
        // Re-entering a token for the same memo must retain the shared baseline.
        if memoID == record.memoID, memoID != nil { record.enabled = true }
        else { record = SyncRecord(enabled: true, memoID: memoID) }
        do { try persist() } catch { report("Could not save sync settings", error: true); return }
        start(client: client)
    }

    func pause() {
        generation = UUID()
        record.enabled = false
        debounce?.cancel()
        do { try persist(); report("Flomo sync paused") }
        catch { report("Could not save the paused state", error: true) }
    }

    func resume() {
        guard client != nil else { report("Connect a Flomo token first.", error: true); return }
        record.enabled = true
        do { try persist(); request() }
        catch { record.enabled = false; report("Could not resume sync", error: true) }
    }

    func localChanged() {
        guard record.enabled else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.request() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func request() {
        guard record.enabled, !running, client != nil else { return }
        Task { await synchronize() }
    }

    func synchronize(choice: SyncChoice? = nil, reviewed: SyncConflict? = nil) async {
        guard record.enabled, !running, let client, let readLocal else { return }
        running = true
        defer { running = false }
        let epoch = generation
        do {
            await settleEditorUpdates()
            guard record.enabled, generation == epoch else { return }
            let rawLocal = try readLocal()
            let local = SyncDocument.normalized(rawLocal)
            guard local.isEmpty && record.memoID != nil || SyncDocument.issue(in: rawLocal) == nil else {
                report(SyncDocument.issue(in: rawLocal)!, error: true); return
            }
            guard SyncDocument.transferFits(local) else {
                report("The note fits locally but needs a little more room for Flomo formatting. Shorten it before syncing.", error: true); return
            }
            report("Syncing with Flomo…")
            if record.memoID == nil {
                guard !record.creationUncertain else {
                    report("A note may already have been created. Connect its Flomo URL to avoid a duplicate.", error: true); return
                }
                record.creationUncertain = true
                record.pendingWrite = local
                try persist() // Record intent before a potentially ambiguous network result.
                let id = try await client.create(content: SyncDocument.toFlomo(local))
                // Always save the returned ID, even when pause was pressed in flight.
                record.memoID = id
                record.creationUncertain = false
                try persist()
            }
            guard let id = record.memoID else { return }
            let remote = try await client.fetch(id: id)
            await settleEditorUpdates()
            guard record.enabled, generation == epoch else { return }
            let currentLocal = try readLocal()
            guard currentLocal == rawLocal else { localChanged(); return }
            let remoteText = SyncDocument.fromFlomo(remote.content)
            guard SyncDocument.issue(in: remoteText) == nil else {
                report("Flomo contains unsupported or oversized content. Sync paused; both copies are preserved.", error: true); return
            }

            if let pending = record.pendingWrite {
                if remoteText == pending {
                    record.baseline = pending
                    record.pendingWrite = nil
                    try persist()
                } else if choice == nil {
                    showConflict(local: rawLocal, remote: remote,
                                 message: "The last write could not be verified. Review both copies.")
                    return
                }
            }

            var direction = SyncComparison.direction(baseline: record.baseline, local: local, remote: remoteText)
            if let choice {
                guard let reviewed, reviewed.local == rawLocal, reviewed.remote == remote else {
                    showConflict(local: rawLocal, remote: remote, message: "A copy changed since review. Review the latest versions."); return
                }
                direction = choice == .local ? .push : .pull
            }
            switch direction {
            case .conflict:
                showConflict(local: rawLocal, remote: remote, message: "Both copies differ. Review before syncing.")
            case .none:
                record.baseline = local
                record.pendingWrite = nil
                try persist()
                conflict = nil
                report("Synced with Flomo")
            case .pull:
                guard let applyRemote else { throw SyncFailure.localUnavailable }
                try applyRemote(rawLocal, remoteText)
                record.baseline = remoteText
                record.pendingWrite = nil
                try persist()
                conflict = nil
                report("Synced from Flomo")
            case .push:
                guard !local.isEmpty else {
                    report("The local note is empty. It will not erase Flomo automatically.", error: true); return
                }
                // Preserve the remote version before an explicit replacement.
                if choice != nil { try backup(remote.content, name: "flomo-before-replacement") }
                record.pendingWrite = local
                try persist()
                try await client.update(id: id, content: SyncDocument.toFlomo(local), updatedAt: remote.updatedAt)
                let verified = try await client.fetch(id: id)
                guard record.enabled, generation == epoch else { return }
                guard SyncDocument.fromFlomo(verified.content) == local else {
                    showConflict(local: try readLocal(), remote: verified,
                                 message: "Flomo changed the formatting. Review before continuing."); return
                }
                record.baseline = local
                record.pendingWrite = nil
                try persist()
                conflict = nil
                report("Synced with Flomo")
            }
        } catch {
            guard generation == epoch else { return }
            if record.memoID == nil, error as? FlomoClientError == .authentication {
                record.creationUncertain = false
                record.pendingWrite = nil
                try? persist()
            }
            // No network failure advances the baseline. A write intent is retained.
            report(error.localizedDescription, error: true)
        }
    }

    private func showConflict(local: String, remote: FlomoMemo, message: String) {
        conflict = SyncConflict(local: local, remote: remote)
        report(message, error: true)
    }

    private func settleEditorUpdates() async {
        // MarkdownEngine publishes NSTextView edits on the next main-queue turn.
        // Drain previously queued publications before capturing/comparing text.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    func backup(_ text: String, name: String) throws {
        let folder = stateURL.deletingLastPathComponent().appendingPathComponent("Sync Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name)-\(UUID().uuidString).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func report(_ text: String, error: Bool = false) {
        status = text
        logger.info("Sync state: \(text, privacy: .public)")
        onStatus?(text, error)
    }

    deinit { timer?.invalidate(); debounce?.cancel() }
}

enum SyncFailure: LocalizedError {
    case localUnavailable, localChanged
    var errorDescription: String? {
        switch self {
        case .localUnavailable: return "The local document is unavailable. Sync stopped."
        case .localChanged: return "The local document changed during sync. Both copies are preserved."
        }
    }
}
