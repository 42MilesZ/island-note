import Foundation

enum DocumentLimits {
    static let limit = 30_000
    static func count(_ text: String) -> Int { text.unicodeScalars.count }
}
