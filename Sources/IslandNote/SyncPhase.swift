import Foundation

enum SyncPhase: Equatable {
    case disconnected, waiting, checking, syncing, synced, paused
    case mergeRequired, conflict, formattingChanged, unsupported, tooLong
    case connectionFailed, authorizationRequired, rateLimited, verifyWrite, recoverCreate, localChanged, failed

    var title: String {
        switch self {
        case .disconnected: return "Connect Flomo…"
        case .waiting: return "Flomo · Changes waiting"
        case .checking: return "Flomo · Checking…"
        case .syncing: return "Flomo · Syncing…"
        case .synced: return "Flomo · Synced"
        case .paused: return "Flomo · Paused"
        case .mergeRequired: return "Flomo · Merge required — Review"
        case .conflict: return "Flomo · Both copies changed — Review"
        case .formattingChanged: return "Flomo · Formatting changed — Review"
        case .unsupported: return "Flomo · Unsupported format — Details"
        case .tooLong: return "Flomo · Note too long — Details"
        case .connectionFailed: return "Flomo · Connection failed — Retry"
        case .authorizationRequired: return "Flomo · Reconnect required"
        case .rateLimited: return "Flomo · Rate limited — Will retry"
        case .verifyWrite: return "Flomo · Verification needed — Review"
        case .recoverCreate: return "Flomo · Find the created memo"
        case .localChanged: return "Flomo · Local edit pending — Retry"
        case .failed: return "Flomo · Sync stopped — Details"
        }
    }

    var symbol: String {
        switch self {
        case .disconnected: return "link"
        case .waiting: return "clock"
        case .checking, .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.circle"
        case .paused: return "pause.circle"
        case .mergeRequired, .conflict: return "arrow.triangle.merge"
        case .connectionFailed: return "wifi.exclamationmark"
        case .authorizationRequired: return "key"
        default: return "exclamationmark.circle"
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
