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
    enum Evaluation: Equatable {
        case waiting, alreadyCommitted, endpoint, cancelled, invalidDelta
        case resize(PanelSize)
        var reason: InteractionDiagnosticReason {
            switch self {
            case .waiting: return .belowThreshold
            case .alreadyCommitted: return .gestureAlreadyHandled
            case .endpoint: return .presetLimit
            case .cancelled: return .gestureCancelled
            case .invalidDelta: return .invalidGesture
            case .resize: return .resizeRequested
            }
        }
    }
    private(set) var isActive = false
    private var magnification: CGFloat = 0
    private var didCommit = false

    mutating func reset() { self = PanelPinch() }

    mutating func update(delta: CGFloat, phase: NSEvent.Phase, size: PanelSize?) -> PanelSize? {
        if case let .resize(target) = evaluate(delta: delta, phase: phase, size: size) { return target }
        return nil
    }

    mutating func evaluate(delta: CGFloat, phase: NSEvent.Phase, size: PanelSize?) -> Evaluation {
        if phase.contains(.began) { reset() }
        if phase.contains(.cancelled) {
            reset()
            return .cancelled
        }
        isActive = true
        defer { if phase.contains(.ended) { reset() } }
        guard delta.isFinite else { return .invalidDelta }
        guard !didCommit else { return .alreadyCommitted }
        magnification += delta
        let target: PanelSize
        if magnification >= 0.08 {
            target = .large
        } else if magnification <= -0.08 {
            target = .standard
        } else {
            return .waiting
        }
        // A gesture toward an existing endpoint is still consumed, so reversing
        // the fingers in the same gesture cannot accidentally toggle the size.
        didCommit = true
        return target == size ? .endpoint : .resize(target)
    }
}
