import AppKit

/// A critically damped follow: gentle acceleration, then a soft landing.
/// Retargeting keeps position and velocity instead of restarting an easing curve.
struct PanelResizeMotion {
    static let frequency: CGFloat = 12
    private(set) var rect: NSRect
    var target: NSRect
    private var velocity = [CGFloat](repeating: 0, count: 4)

    init(rect: NSRect) { self.rect = rect; target = rect }

    mutating func advance(by elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let dt = CGFloat(elapsed), w = Self.frequency, decay = exp(-w * dt)
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        let goals = [target.minX, target.minY, target.width, target.height]
        var next = values
        for index in values.indices {
            let error = values[index] - goals[index]
            let carry = velocity[index] + w * error
            next[index] = goals[index] + (error + carry * dt) * decay
            velocity[index] = (velocity[index] - w * carry * dt) * decay
        }
        rect = NSRect(x: next[0], y: next[1], width: next[2], height: next[3])
    }

    mutating func constrain(to visible: NSRect) {
        let old = [rect.minX, rect.minY, rect.width, rect.height]
        let new = [visible.minX, visible.minY, visible.width, visible.height]
        for index in old.indices where abs(old[index] - new[index]) > 0.00001 { velocity[index] = 0 }
        rect = visible
    }

    var isSettled: Bool {
        let distance = [rect.minX - target.minX, rect.minY - target.minY,
                        rect.width - target.width, rect.height - target.height]
        return distance.allSatisfy { abs($0) < 0.15 } && velocity.allSatisfy { abs($0) < 3 }
    }
}
