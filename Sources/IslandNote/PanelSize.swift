import AppKit

enum PanelSize: String {
    case standard, large

    var dimensions: NSSize {
        switch self {
        case .standard: return NSSize(width: 460, height: 275)
        case .large: return NSSize(width: 690, height: 550)
        }
    }

    var floatingDimensions: NSSize {
        switch self {
        case .standard: return NSSize(width: 420, height: 460)
        case .large: return NSSize(width: 560, height: 620)
        }
    }
}

/// Accumulate native magnification deltas and commit at most once per gesture.
struct PanelPinch {
    private(set) var isActive = false
    private var magnification: CGFloat = 0
    private var didCommit = false

    mutating func reset() { self = PanelPinch() }

    mutating func update(delta: CGFloat, phase: NSEvent.Phase, size: PanelSize?) -> PanelSize? {
        if phase.contains(.began) { reset() }
        if phase.contains(.cancelled) {
            reset()
            return nil
        }
        isActive = true
        defer { if phase.contains(.ended) { reset() } }
        guard !didCommit, delta.isFinite else { return nil }
        magnification += delta
        let target: PanelSize
        if magnification >= 0.08 {
            target = .large
        } else if magnification <= -0.08 {
            target = .standard
        } else {
            return nil
        }
        // A gesture toward an existing endpoint is still consumed, so reversing
        // the fingers in the same gesture cannot accidentally toggle the size.
        didCommit = true
        return target == size ? nil : target
    }
}
