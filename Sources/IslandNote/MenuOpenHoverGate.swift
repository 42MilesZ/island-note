import AppKit

/// Menu opening must finish before a new physical pointer movement can dismiss it.
struct MenuOpenHoverGate {
    private(set) var isActive = false
    private var lastPoint: NSPoint?
    private var completedAt: TimeInterval = 0

    mutating func begin() {
        isActive = true
        lastPoint = nil
        completedAt = 0
    }

    mutating func openingFinished(at point: NSPoint, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isActive else { return }
        lastPoint = point
        completedAt = timestamp
    }

    mutating func allowsHover(at point: NSPoint, isMovement: Bool,
                             timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard isActive else { return true }
        guard let previous = lastPoint, isMovement, timestamp > completedAt, previous != point else { return false }
        lastPoint = point
        return true
    }

    mutating func reset() {
        isActive = false
        lastPoint = nil
    }
}
