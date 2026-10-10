import Foundation
import OSLog

struct PendingMerge: Codable, Equatable {
    let localBefore: String
    let merged: String
    let remoteBefore: String
}

struct SyncRecord: Codable, Equatable {
    var enabled = false
    var memoID: String?
    var baseline: String?
    var remoteBaseline: String?
    var pendingWrite: String?
    var pendingEncodedContent: String?
    var pendingMerge: PendingMerge?
    var creationUncertain = false
    var lastVerifiedAt: Date?
    // Persist unresolved review independently of activity, pause and transport errors.
    var reviewPhase: SyncPhase?
}

enum SyncTrigger: String { case startup, timer, edit, panel, manual, recovery }

enum SyncChoice { case local, remote, merge }

struct SyncConflict {
    let local: String
    let remote: FlomoMemo
}

enum SyncDirection: Equatable { case none, push, pull, conflict }

enum SyncComparison {
    static func direction(baseline: String?, remoteBaseline: String? = nil, local: String, remote: String) -> SyncDirection {
        if SyncDocument.equivalent(local: local, remote: remote) { return .none }
        guard let baseline else { return .conflict }
        let localChanged = !SyncDocument.equivalent(local: baseline, remote: local)
        guard let remoteBaseline else {
            // Old records lack the exact remote representation; don't assume
            // formatting differences are changes safe to pull automatically.
            return SyncDocument.equivalent(local: baseline, remote: remote) ? .push : .conflict
        }
        let remoteChanged = !SyncDocument.equivalent(local: remoteBaseline, remote: remote)
        if !localChanged && !remoteChanged { return .none }
        if !localChanged { return .pull }
        if !remoteChanged { return .push }
        return .conflict
    }
}

@MainActor
final class FlomoSync {
    private(set) var record: SyncRecord
    private(set) var status = L10n.tr("Flomo not connected")
    private(set) var requiresReconnection = false
    private(set) var conflict: SyncConflict?
    private(set) var phase: SyncPhase = .disconnected
    var onStatus: ((SyncPhase, String) -> Void)?
    /// Must flush pending editor changes and read the current file each time.
    var readLocal: (() throws -> String)?
    /// Compare the editor/file against expected before applying; save a backup.
    var applyRemote: ((_ expected: String, _ replacement: String) throws -> Void)?
    private let stateURL: URL
    private let pollingInterval: TimeInterval
    private var client: FlomoServing?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var running = false
    var isBusy: Bool { running }
    var isStopped: Bool { stopped }
    private var stopped = false
    private var rawStatus = "Flomo not connected"
    private var generation = UUID()
    private let logger = Logger(subsystem: "local.projects.island-note", category: "FlomoSync")

    init(stateURL: URL, pollingInterval: TimeInterval = 60) throws {
        self.stateURL = stateURL
        self.pollingInterval = pollingInterval
        if FileManager.default.fileExists(atPath: stateURL.path) {
            record = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: stateURL))
        } else { record = SyncRecord() }
        if record.reviewPhase == nil {
            if record.creationUncertain { record.reviewPhase = .recoverCreate }
            else if record.pendingWrite != nil || record.pendingMerge != nil { record.reviewPhase = .verifyWrite }
        }
        phase = record.reviewPhase ?? .disconnected
    }

    func start(client: FlomoServing) {
        guard !stopped else { return }
        self.client = client
        client.setRequestsEnabled(record.enabled)
        timer?.invalidate()
        let pollingTimer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.request(source: .timer) }
        }
        timer = pollingTimer
        RunLoop.main.add(pollingTimer, forMode: .common)
        if record.enabled { request(source: .startup) }
        else { report("Automatic sync is paused. Local changes still save to disk.", phase: .paused) }
    }

    func connect(client: FlomoServing, memoID: String?) async {
        guard !stopped else { return }
        guard !running else { report("Wait for the current sync to finish"); return }
        guard !record.creationUncertain || memoID != nil else {
            report("A note may already exist. Use Find Existing Memo before reconnecting.", phase: .recoverCreate); return
        }
        generation = UUID()
        // Re-entering a token for the same memo must retain the shared baseline.
        if memoID == record.memoID, memoID != nil { record.enabled = true }
        else { record = SyncRecord(enabled: true, memoID: memoID) }
        do { try persist() } catch { report("Could not save sync settings"); return }
        start(client: client)
    }

    /// Disable the extension without deleting its credentials, memo or write intent.
    /// Already-sent writes may complete; their returned IDs must still be retained.
    func stop() {
        stopped = true
        client?.setRequestsEnabled(false)
        generation = UUID()
        report("Flomo extension is off. Local notes and the previous sync preference are retained.", phase: .paused)
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        client = nil
    }

    func allowConnections() { stopped = false }

    func pause() {
        client?.setRequestsEnabled(false)
        generation = UUID()
        record.enabled = false
        debounce?.cancel()
        do { try persist(); report("Automatic sync is paused. Local changes still save to disk.", phase: .paused) }
        catch { report("Could not save the paused state") }
    }

    func resume() {
        guard client != nil else { report("Connect a Flomo token first.", phase: .authorizationRequired); return }
        client?.setRequestsEnabled(true)
        record.enabled = true
        do { try persist(); request(source: .recovery) }
        catch { record.enabled = false; report("Could not resume sync") }
    }

    func localChanged() {
        guard !stopped, record.enabled else { return }
        debounce?.cancel()
        if conflict == nil, !running { report("Saved locally. Sync starts after 3 seconds without edits.", phase: .waiting) }
        let work = DispatchWorkItem { [weak self] in self?.request(source: .edit) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func request(source: SyncTrigger = .manual) {
        guard !stopped, record.enabled, !running, client != nil else { return }
        logger.info("Sync requested: \(source.rawValue, privacy: .public)")
        Task { await synchronize() }
    }

    /// Fetch fresh comparison copies for review without uploading or pulling.
    /// Paused sync stays paused; its already captured copies can still be viewed.
    func prepareReview() async {
        guard !stopped, record.enabled, !running, let client, let readLocal, let id = record.memoID else { return }
        running = true
        defer { running = false }
        let epoch = generation
        logger.info("Sync requested: review")
        do {
            await settleEditorUpdates()
            guard generation == epoch, record.enabled else { return }
            let remote = try await client.fetch(id: id)
            requiresReconnection = false
            await settleEditorUpdates()
            guard generation == epoch, record.enabled else { return }
            showConflict(local: try readLocal(), remote: remote, message: "Review the latest local and Flomo copies before continuing.",
                         phase: record.reviewPhase ?? .conflict)
        } catch {
            guard generation == epoch else { return }
            requiresReconnection = error as? FlomoClientError == .authentication
            report((error as? FlomoClientError)?.messageKey ?? error.localizedDescription,
                   phase: error as? FlomoClientError == .authentication ? .authorizationRequired : .connectionFailed)
        }
    }

    func synchronize(choice: SyncChoice? = nil, reviewed: SyncConflict? = nil) async {
        guard !stopped, record.enabled, !running, let client, let readLocal else { return }
        running = true
        defer { running = false }
        let epoch = generation
        var writeAttemptInFlight = false
        var beforeUnsentIntent: SyncRecord?
        var priorWriteIntent: SyncRecord?
        do {
            await settleEditorUpdates()
            guard record.enabled, generation == epoch else { return }
            let rawLocal = try readLocal()
            let local = SyncDocument.normalized(rawLocal)
            guard local.isEmpty && record.memoID != nil || SyncDocument.issue(in: rawLocal) == nil else {
                report(SyncDocument.issue(in: rawLocal)!, phase: SyncDocument.count(rawLocal) > SyncDocument.limit ? .tooLong : .unsupported); return
            }
            guard SyncDocument.transferFits(local) else {
                report("The note fits locally but needs a little more room for Flomo formatting. Shorten it before syncing.", phase: .tooLong); return
            }
            if conflict == nil { report("Checking the linked memo before applying any changes.", phase: .checking) }
            if record.memoID == nil {
                guard !record.creationUncertain else {
                    report("A note may already have been created. Use Find Existing Memo to avoid a duplicate.", phase: .recoverCreate); return
                }
                beforeUnsentIntent = record
                priorWriteIntent = record
                record.creationUncertain = true
                record.pendingWrite = local
                record.pendingEncodedContent = SyncDocument.toFlomo(local)
                try persist() // Record intent before a potentially ambiguous network result.
                report("Creating one dedicated Flomo memo…", phase: .syncing)
                beforeUnsentIntent = nil
                writeAttemptInFlight = true
                let id = try await client.create(content: SyncDocument.toFlomo(local))
                writeAttemptInFlight = false
                // Always save the returned ID, even when pause was pressed in flight.
                record.memoID = id
                record.creationUncertain = false
                try persist()
            }
            guard record.enabled, generation == epoch, let id = record.memoID else { return }
            let remote = try await client.fetch(id: id)
            requiresReconnection = false
            await settleEditorUpdates()
            guard record.enabled, generation == epoch else { return }
            let currentLocal = try readLocal()
            guard currentLocal == rawLocal else {
                report("Local edits are waiting to sync after typing stops.", phase: .waiting)
                localChanged()
                return
            }
            let remoteText = SyncDocument.fromFlomo(remote.content)
            guard SyncDocument.issue(in: remoteText) == nil else {
                report("Flomo: " + (SyncDocument.issue(in: remoteText) ?? "Unsupported content"), phase: .unsupported); return
            }

            var recoveredMerge = false
            if let intent = record.pendingMerge {
                if local == intent.merged {
                    record.baseline = intent.remoteBefore
                    record.remoteBaseline = intent.remoteBefore
                    recoveredMerge = true
                } else if rawLocal != intent.localBefore, choice == nil || choice == .merge {
                    showConflict(local: rawLocal, remote: remote, message: "The previous merge was interrupted and the local note changed. Review the saved copies before continuing.")
                    return
                }
                record.pendingMerge = nil
                try persist()
            }
            let wasAwaitingVerification = record.pendingWrite != nil || recoveredMerge
            var repairLegacyUpload = false
            if let pending = record.pendingWrite {
                if SyncDocument.equivalent(local: pending, remote: remoteText) {
                    record.remoteBaseline = remoteText
                    record.baseline = pending
                    record.pendingWrite = nil
                    record.pendingEncodedContent = nil
                    try persist()
                } else if SyncDocument.isLegacyTransportLoss(local: pending, remote: remoteText),
                          record.pendingEncodedContent != SyncDocument.toFlomo(pending) {
                    // Retry a known old encoder defect once with the corrected
                    // payload, conditional on this exact remote version. Any
                    // other content change still requires review.
                    repairLegacyUpload = true
                } else if choice == nil {
                    showConflict(local: rawLocal, remote: remote,
                                 message: "The last write could not be verified. Review both copies before continuing.", phase: .verifyWrite)
                    return
                }
            }

            var direction = repairLegacyUpload ? .push : SyncComparison.direction(baseline: record.baseline, remoteBaseline: record.remoteBaseline, local: local, remote: remoteText)
            if let choice {
                guard let reviewed, reviewed.local == rawLocal, reviewed.remote == remote else {
                    showConflict(local: rawLocal, remote: remote, message: "A copy changed since review. Review the latest versions."); return
                }
                if choice == .merge {
                    guard !wasAwaitingVerification else {
                        report("A combined version is already waiting for verification. Review or retry that version; merging again would duplicate text.", phase: .verifyWrite)
                        return
                    }
                    let merged = SyncDocument.merging(local: rawLocal, remote: remoteText)
                    guard SyncDocument.issue(in: merged) == nil, SyncDocument.transferFits(merged) else {
                        report("The merged note is too large or contains unsupported syntax. Both copies are preserved.", phase: .unsupported); return
                    }
                    guard let applyRemote else { throw SyncFailure.localUnavailable }
                    try backup(remote.content, name: "flomo-before-merge")
                    record.pendingMerge = PendingMerge(localBefore: rawLocal, merged: merged, remoteBefore: remoteText)
                    try persist()
                    try applyRemote(rawLocal, merged)
                    // The existing remote version is the comparison baseline for
                    // the next upload; fetch it again to detect intervening edits.
                    record.remoteBaseline = remoteText
                    record.baseline = remoteText
                    record.pendingWrite = nil
                    record.pendingEncodedContent = nil
                    record.pendingMerge = nil
                    record.reviewPhase = nil
                    try persist()
                    conflict = nil
                    report("Both copies are merged locally. The combined note is waiting to upload.", phase: .waiting)
                    localChanged()
                    return
                }
                direction = choice == .local ? .push : .pull
            }
            switch direction {
            case .conflict:
                showConflict(local: rawLocal, remote: remote, message: record.baseline == nil ? "The linked memo and Island Note contain different text. Click Merge Both to preserve both in this same memo." : "Both copies changed since the last sync. Review them before continuing.", phase: record.baseline == nil ? .mergeRequired : .conflict)
            case .none:
                record.lastVerifiedAt = Date()
                record.remoteBaseline = remoteText
                record.baseline = local
                record.pendingWrite = nil
                record.pendingEncodedContent = nil
                record.reviewPhase = nil
                try persist()
                conflict = nil
                report("Both copies are up to date.", phase: .synced)
            case .pull:
                guard let applyRemote else { throw SyncFailure.localUnavailable }
                try applyRemote(rawLocal, remoteText)
                record.lastVerifiedAt = Date()
                record.remoteBaseline = remoteText
                record.baseline = remoteText
                record.pendingWrite = nil
                record.pendingEncodedContent = nil
                record.reviewPhase = nil
                try persist()
                conflict = nil
                report("Flomo changes were saved to the local document.", phase: .synced)
            case .push:
                guard !local.isEmpty else {
                    report("The local note is empty. It will not erase Flomo automatically."); return
                }
                // Preserve the remote version before an explicit replacement.
                if choice != nil { try backup(remote.content, name: "flomo-before-replacement") }
                if repairLegacyUpload { try backup(remote.content, name: "flomo-before-format-repair") }
                beforeUnsentIntent = beforeUnsentIntent ?? record
                priorWriteIntent = priorWriteIntent ?? record
                record.pendingWrite = local
                record.pendingEncodedContent = SyncDocument.toFlomo(local)
                try persist()
                report("Uploading local changes and verifying the saved memo…", phase: .syncing)
                beforeUnsentIntent = nil
                writeAttemptInFlight = true
                try await client.update(id: id, content: SyncDocument.toFlomo(local), updatedAt: remote.updatedAt)
                writeAttemptInFlight = false
                guard !stopped, record.enabled, generation == epoch else { return }
                let verified = try await client.fetch(id: id)
                guard record.enabled, generation == epoch else { return }
                guard SyncDocument.equivalent(local: local, remote: SyncDocument.fromFlomo(verified.content)) else {
                    showConflict(local: try readLocal(), remote: verified,
                                 message: "The verified Flomo content differs from the uploaded note. Review both copies before continuing.", phase: .formattingChanged); return
                }
                await settleEditorUpdates()
                guard record.enabled, generation == epoch else { return }
                let editedDuringUpload = SyncDocument.normalized(try readLocal()) != local
                if !editedDuringUpload { record.lastVerifiedAt = Date() }
                record.remoteBaseline = SyncDocument.fromFlomo(verified.content)
                record.baseline = local
                record.pendingWrite = nil
                record.pendingEncodedContent = nil
                record.reviewPhase = nil
                try persist()
                conflict = nil
                if editedDuringUpload {
                    report("The earlier upload was verified. New local edits are waiting to sync.", phase: .waiting)
                    localChanged()
                } else { report("Both copies are up to date.", phase: .synced) }
            }
        } catch {
            if let beforeUnsentIntent {
                // Persistence failed before entering the network call. Restore
                // the earlier intent, including any unresolved older write.
                record = beforeUnsentIntent
                try? persist()
            }
            var cause = error
            var definitelyNotWritten = false
            if let clientError = error as? FlomoClientError {
                switch clientError {
                case .writeNotIssued(let reason): cause = reason; definitelyNotWritten = true
                case .cancelledBeforeWrite, .authentication, .rateLimited, .conflict: definitelyNotWritten = true
                default: break
                }
            }
            if writeAttemptInFlight && definitelyNotWritten {
                record.creationUncertain = priorWriteIntent?.creationUncertain ?? false
                record.pendingWrite = priorWriteIntent?.pendingWrite
                record.pendingEncodedContent = priorWriteIntent?.pendingEncodedContent
                try? persist()
            }
            guard generation == epoch else {
                if writeAttemptInFlight && definitelyNotWritten {
                    let active = record.enabled && !stopped
                    report(active ? "Local edits are waiting to sync after typing stops." : "Automatic sync is paused. Local changes still save to disk.",
                           phase: active ? .waiting : .paused)
                    if active { localChanged() }
                }
                return
            }
            requiresReconnection = cause as? FlomoClientError == .authentication
            // No network failure advances the baseline. A write intent is retained.
            let failurePhase: SyncPhase
            switch cause {
            case FlomoClientError.authentication: failurePhase = .authorizationRequired
            case FlomoClientError.rateLimited: failurePhase = .rateLimited
            case FlomoClientError.unavailable: failurePhase = .connectionFailed
            case FlomoClientError.offline: failurePhase = .offline
            case FlomoClientError.unknownWriteOutcome: failurePhase = record.memoID == nil ? .recoverCreate : .verifyWrite
            case FlomoClientError.incompleteMemo: failurePhase = .verifyWrite
            case FlomoClientError.attachmentsUnsupported: failurePhase = .unsupported
            case FlomoClientError.conflict: failurePhase = .conflict
            case SyncFailure.localChanged: failurePhase = .localChanged
            default: failurePhase = .failed
            }
            if record.creationUncertain { record.reviewPhase = .recoverCreate }
            else if record.reviewPhase == nil && record.pendingWrite != nil { record.reviewPhase = .verifyWrite }
            if failurePhase == .conflict { record.reviewPhase = .conflict }
            do { try persist() } catch { logger.error("Could not persist sync review state") }
            report((cause as? FlomoClientError)?.messageKey ?? (cause as? SyncFailure)?.messageKey ?? cause.localizedDescription, phase: failurePhase)
        }
    }

    private func showConflict(local: String, remote: FlomoMemo, message: String, phase: SyncPhase = .conflict) {
        conflict = SyncConflict(local: local, remote: remote)
        record.reviewPhase = phase
        do { try persist() } catch { logger.error("Could not persist sync review state") }
        report(message, phase: phase)
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

    func refreshLanguage() { report(rawStatus, phase: phase) }

    private func report(_ text: String, phase: SyncPhase = .failed) {
        // An interrupted in-flight write is uncertain until a later read verifies
        // it. Neither pause nor an unrelated transport failure resolves it.
        let effectivePhase = record.reviewPhase ?? (phase == .paused && record.creationUncertain ? .recoverCreate
            : phase == .paused && (record.pendingWrite != nil || record.pendingMerge != nil) ? .verifyWrite : phase)
        self.phase = effectivePhase
        rawStatus = text
        status = L10n.tr(text)
        if effectivePhase != phase { status = effectivePhase.title + "\n" + status }
        if let verified = record.lastVerifiedAt {
            status += "\n" + L10n.tr("Last verified: ") + verified.formatted(date: .abbreviated, time: .shortened)
        }
        logger.info("Sync state: \(text, privacy: .public)")
        onStatus?(effectivePhase, status)
    }

    deinit { timer?.invalidate(); debounce?.cancel() }
}

enum SyncFailure: LocalizedError {
    case localUnavailable, localChanged
    var errorDescription: String? { L10n.tr(messageKey) }

    var messageKey: String {
        switch self {
        case .localUnavailable: return "The local document is unavailable. Sync stopped."
        case .localChanged: return "The local document changed during sync. Both copies are preserved."
        }
    }
}
