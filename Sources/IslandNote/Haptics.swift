import AppKit

/// Trackpad Taptic — 清脆单击。展开一次、收起一次，不叠拍。
enum Haptics {
    /// 清脆一记「嗒」——展开。
    static func expand() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// 清脆一记「嗒」——收起（同展开，只响一次）。
    static func collapse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
