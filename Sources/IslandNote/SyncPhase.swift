import Foundation

enum SyncPhase: Equatable {
    case disconnected, waiting, checking, syncing, synced, paused
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
        case .mergeRequired: return L10n.tr("Flomo · Merge required — Review")
        case .conflict: return L10n.tr("Flomo · Both copies changed — Review")
        case .formattingChanged: return L10n.tr("Flomo · Formatting changed — Review")
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
        case .disconnected: return L10n.tr("Local only · Connect Flomo")
        case .mergeRequired: return L10n.tr("Merge needed · Click to review")
        case .conflict: return L10n.tr("Conflicting edits · Click to review")
        case .formattingChanged: return L10n.tr("Formatting changed · Click to review")
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
    var needsAction: Bool {
        switch self {
        case .disconnected, .waiting, .checking, .syncing, .synced, .paused: return false
        default: return true
        }
    }
}
