import AppKit
import QuartzCore

enum SettingsPalette {
    private static func color(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static let page = color(NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1), NSColor(white: 0.082, alpha: 1))
    static let card = color(.white, NSColor(white: 0.141, alpha: 1))
    static let ink = color(NSColor(white: 0.067, alpha: 1), NSColor(white: 0.961, alpha: 1))
    static let secondary = color(NSColor(srgbRed: 0.384, green: 0.384, blue: 0.408, alpha: 1), NSColor(white: 0.68, alpha: 1))
    static let subtle = color(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.055))
    static let hover = color(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.10))
    static let pressed = color(NSColor(white: 0, alpha: 0.13), NSColor(white: 1, alpha: 0.16))
    static let inverse = color(.white, NSColor(white: 0.082, alpha: 1))
    static let off = color(NSColor(white: 0.84, alpha: 1), NSColor(white: 0.30, alpha: 1))
    static func animate(_ layer: CALayer, key: String, value: Any, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        animation.toValue = value
        animation.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key); CATransaction.commit()
        layer.add(animation, forKey: key)
    }
}

final class SettingsSurface: NSView {
    enum Role { case page, card }
    private let role: Role
    init(role: Role) {
        self.role = role; super.init(frame: .zero); wantsLayer = true
        if role == .card { layer?.cornerRadius = 24; layer?.cornerCurve = .continuous }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = (role == .page ? SettingsPalette.page : SettingsPalette.card).cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class SettingsButton: NSButton {
    private let quiet: Bool
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    init(title: String, target: AnyObject?, action: Selector?, quiet: Bool = false) {
        self.quiet = quiet; super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        isBordered = false; bezelStyle = .regularSquare
        font = .systemFont(ofSize: 13, weight: .regular)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        if !title.isEmpty { widthAnchor.constraint(greaterThanOrEqualToConstant: (title as NSString).size(withAttributes: [.font: font!]).width + 28).isActive = true }
        updateColors(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isEnabled: Bool { didSet { updateColors(animated: false) } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors(animated: false) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateColors(animated: true) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateColors(animated: true) }
    override func highlight(_ flag: Bool) { super.highlight(flag); pressed = flag; updateColors(animated: true) }
    private func updateColors(animated: Bool) {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contentTintColor = isEnabled ? SettingsPalette.ink : SettingsPalette.secondary.withAlphaComponent(0.4)
            let color = !isEnabled ? (quiet ? .clear : SettingsPalette.subtle)
                : pressed ? SettingsPalette.pressed : hovered ? SettingsPalette.hover : quiet ? .clear : SettingsPalette.subtle
            if animated { SettingsPalette.animate(layer, key: "backgroundColor", value: color.cgColor, duration: 0.16) }
            else { layer.backgroundColor = color.cgColor }
        }
    }
}

/// Native button semantics, with a monochrome thumb that resumes from its presentation position.
final class SettingsSwitch: NSButton {
    private let rail = CALayer()
    private let thumb = CALayer()
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = ""; self.target = target; self.action = action
        setButtonType(.pushOnPushOff); isBordered = false
        setAccessibilityLabel(title); setAccessibilityRole(.checkBox)
        wantsLayer = true; layer?.addSublayer(rail); rail.addSublayer(thumb)
        rail.cornerRadius = 13; thumb.cornerRadius = 10
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 46), heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var state: NSControl.StateValue { didSet { if oldValue != state { updateSwitch(animated: window != nil) } } }
    override func draw(_ dirtyRect: NSRect) { /* Layer draws the switch; NSButton retains keyboard and accessibility handling. */ }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 13, yRadius: 13).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateEmphasis() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateEmphasis() }
    override func highlight(_ flag: Bool) { super.highlight(flag); pressed = flag; updateEmphasis() }
    private func updateEmphasis() {
        SettingsPalette.animate(rail, key: "opacity", value: pressed ? 0.76 : hovered ? 0.90 : 1.0, duration: 0.16)
    }
    override func layout() { super.layout(); updateSwitch(animated: false) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSwitch(animated: false) }
    private func updateSwitch(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rail.frame = CGRect(x: 1, y: 1, width: 44, height: 26)
            thumb.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
            thumb.backgroundColor = SettingsPalette.inverse.cgColor
            CATransaction.commit()
            let position = CGPoint(x: state == .on ? 31 : 13, y: 13)
            let color = (state == .on ? SettingsPalette.ink : SettingsPalette.off).cgColor
            if animated {
                SettingsPalette.animate(thumb, key: "position", value: position, duration: 0.24)
                SettingsPalette.animate(rail, key: "backgroundColor", value: color, duration: 0.24)
            } else {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                thumb.position = position; rail.backgroundColor = color; CATransaction.commit()
            }
            setAccessibilityValue(state == .on ? 1 : 0)
        }
    }
}
