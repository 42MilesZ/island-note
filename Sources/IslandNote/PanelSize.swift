import AppKit

enum PanelSize: String {
    case standard, large

    var dimensions: NSSize {
        switch self {
        case .standard: return NSSize(width: 460, height: 275)
        case .large: return NSSize(width: 690, height: 550)
        }
    }
}
