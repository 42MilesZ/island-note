import Foundation

enum SyncPhase: String, Codable, Equatable {
    case disconnected, waiting, checking, syncing, synced, paused, offline
    case mergeRequired, conflict, formattingChanged, unsupported, tooLong
    case connectionFailed, authorizationRequired, rateLimited, verifyWrite, recoverCreate, localChanged, failed

    var title: String {
        switch self {
        case .disconnected: return L10n.tr("Connect Flomo…")
        case .waiting: return L10n.tr("Flomo · Changes waiting")
        case .checking: return L10n.tr("Flomo · Checking…")
        case .syncing: return L10n.tr("Flomo · Syncing…")
        case .synced: return L10n.tr("Flomo · Synced")
        case .paused: return L10n.tr("Flomo · Paused")
        case .offline: return L10n.tr("Flomo · Offline")
        case .mergeRequired: return L10n.tr("Flomo · Merge required — Review")
        case .conflict: return L10n.tr("Flomo · Both copies changed — Review")
        case .formattingChanged: return L10n.tr("Flomo · Content differs — Review")
        case .unsupported: return L10n.tr("Flomo · Unsupported format — Details")
        case .tooLong: return L10n.tr("Flomo · Note too long — Details")
        case .connectionFailed: return L10n.tr("Flomo · Connection failed — Retry")
        case .authorizationRequired: return L10n.tr("Flomo · Reconnect required")
        case .rateLimited: return L10n.tr("Flomo · Rate limited — Will retry")
        case .verifyWrite: return L10n.tr("Flomo · Verification needed — Review")
        case .recoverCreate: return L10n.tr("Flomo · Find the created memo")
        case .localChanged: return L10n.tr("Flomo · Local edit pending — Retry")
        case .failed: return L10n.tr("Flomo · Sync stopped — Details")
        }
    }

    var hoverSummary: String {
        switch self {
        case .synced: return L10n.tr("Saved · Synced")
        case .checking: return L10n.tr("Saved · Checking sync")
        case .syncing: return L10n.tr("Saved · Syncing…")
        case .waiting: return L10n.tr("Saved · Sync pending")
        case .paused: return L10n.tr("Saved · Sync paused")
        case .offline: return L10n.tr("Saved · Offline")
        case .disconnected: return L10n.tr("Local only · Connect Flomo")
        case .mergeRequired: return L10n.tr("Merge needed · Click to review")
        case .conflict: return L10n.tr("Conflicting edits · Click to review")
        case .formattingChanged: return L10n.tr("Content differs · Click to review")
        case .connectionFailed: return L10n.tr("Connection failed · Click to retry")
        case .authorizationRequired: return L10n.tr("Reconnect Flomo")
        case .rateLimited: return L10n.tr("Sync delayed · Retrying later")
        case .unsupported: return L10n.tr("Unsupported format · View details")
        case .tooLong: return L10n.tr("Note too long · View details")
        case .verifyWrite: return L10n.tr("Verify sync · Click to review")
        case .recoverCreate: return L10n.tr("Link existing memo")
        case .localChanged: return L10n.tr("Local changes pending")
        case .failed: return L10n.tr("Sync stopped · View details")
        }
    }

    var isBusy: Bool { self == .checking || self == .syncing }
    var inlineStatus: String? {
        switch self {
        case .syncing: return L10n.tr("Syncing…")
        case .conflict, .mergeRequired: return L10n.tr("Conflict")
        case .formattingChanged: return L10n.tr("Content differs")
        case .verifyWrite: return L10n.tr("Sync unconfirmed")
        case .recoverCreate: return L10n.tr("Memo unconfirmed")
        case .authorizationRequired: return L10n.tr("Reconnect Flomo")
        case .unsupported: return L10n.tr("Unsupported format")
        case .tooLong: return L10n.tr("Note too long")
        case .connectionFailed: return L10n.tr("Connection failed")
        case .failed: return L10n.tr("Sync failed")
        default: return nil
        }
    }
    var needsAction: Bool {
        switch self {
        case .disconnected, .waiting, .checking, .syncing, .synced, .paused, .offline, .rateLimited, .localChanged: return false
        default: return true
        }
    }
}

enum LocalSaveState: Equatable {
    case loading, saving, saved
    case failed(String)
}

/// One mapping owns the visible caption and tone. Success always refers to the
/// current durable local version; a brief save pulse cannot imply remote success.
struct StatusPresentation: Equatable {
    enum Tone { case neutral, busy, success, warning, error }
    let tone: Tone
    let caption: String?
    let summary: String

    init(local: LocalSaveState, phase: SyncPhase, flomoEnabled: Bool, hovered: Bool) {
        if case .failed = local {
            tone = .error
            summary = L10n.tr("Not saved · Click for details")
            caption = hovered ? summary : L10n.tr("Not saved")
            return
        }
        let effectivePhase = local != .saved && phase == .synced ? SyncPhase.waiting : phase
        if flomoEnabled && effectivePhase.needsAction { tone = .warning }
        else if flomoEnabled && effectivePhase.isBusy { tone = .busy }
        else if local == .saved && (!flomoEnabled || effectivePhase == .synced) { tone = .success }
        else { tone = .neutral }
        if local == .loading { summary = L10n.tr("Loading note…") }
        else if local == .saving {
            summary = flomoEnabled && effectivePhase.needsAction ? effectivePhase.hoverSummary
                : L10n.tr("Saving locally…")
        } else { summary = flomoEnabled ? effectivePhase.hoverSummary : L10n.tr("Saved locally") }
        let automatic = flomoEnabled ? effectivePhase.inlineStatus : nil
        caption = hovered ? summary : automatic
    }
}
