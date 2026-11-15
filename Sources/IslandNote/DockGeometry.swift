import AppKit

/// 屏幕顶部摄像头刘海的尺寸（point）。
///
/// macOS 没有公开刘海轮廓或圆角的 API，只能从两项公开数据推出外接矩形：
/// - `safeAreaInsets.top`：刘海高度，无刘海屏幕为 0；
/// - `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`：刘海两侧可用区域，屏宽减去两者即刘海宽度。
///
/// 物理刘海的像素尺寸固定，但「显示器 > 缩放」改变后 point 值会随之变化，
/// 不同机型（14/16 英寸 Pro、13/15 英寸 Air）也不同，因此不能写死，需在屏幕参数变化时重新读取。
struct NotchMetrics: Equatable {
    /// nil 表示该屏幕没有刘海（外接显示器、无刘海的 Mac、合盖后只剩外屏）。
    let size: NSSize?

    var hasNotch: Bool { size != nil }

    init(screenWidth: CGFloat, safeAreaTop: CGFloat, topLeftArea: NSRect?, topRightArea: NSRect?) {
        guard safeAreaTop > 0, let left = topLeftArea, let right = topRightArea else {
            size = nil
            return
        }
        let width = screenWidth - left.width - right.width
        // A tiny residual gap means the auxiliary areas meet; there is no camera housing.
        size = width > 40 ? NSSize(width: width, height: safeAreaTop) : nil
    }

    init(screen: NSScreen) {
        self.init(screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
                  topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea)
    }
}

/// 停靠态岛体（休息 / 悬停）的几何，坐标系为面板画布（原点左下，`canvasTop` 为屏幕最顶）。
///
/// 无刘海时休息态完全不可见：常驻黑条在半透明菜单栏上像显示缺陷，也会遮住菜单栏内容。
/// 指针靠近（`peekZone`）时只从顶边探出一条细边（`hover`）作为提示；
/// 推到顶边，或在菜单栏这一条（`openZone`）稍作停留，才展开。
/// 收起 / 探出都让圆角胶囊从顶边外滑入滑出（`retracted`），全程保留圆角。
struct DockBarLayout: Equatable {
    /// 无刘海时作为停靠锚点的名义尺寸，也是有刘海时的下限。
    static let fallbackNotchWidth: CGFloat = 200
    static let minimumHeight: CGFloat = 33
    /// 无刘海时的探头细边。
    static let peekHeight: CGFloat = 6
    static let peekWidthRatio: CGFloat = 0.6
    /// 菜单栏自动隐藏时 visibleFrame 不再扣除菜单栏，感应区退化为顶边这一条。
    static let minimumRevealDepth: CGFloat = 8
    /// 探头区比打开区更宽、更深：靠近就有提示，但只在菜单栏内停留才会打开，
    /// 避免指针经过窗口标题栏时误开。
    static let peekMargin: CGFloat = 40
    static let peekExtraDepth: CGFloat = 16
    static let openMargin: CGFloat = 24
    /// 指针被屏幕顶边挡住的那几行：在这里视为明确想打开，无需停留。
    static let edgeDepth: CGFloat = 3

    let notch: NotchMetrics
    /// 停靠锚点与有刘海时的休息态胶囊。
    let rest: NSRect
    let hover: NSRect
    /// 无刘海时出现探头提示的范围。
    let peekZone: NSRect
    /// 无刘海时停留即展开的范围：菜单栏这一条。
    let openZone: NSRect

    init(notch: NotchMetrics, canvasWidth: CGFloat, canvasTop: CGFloat, menuBarHeight: CGFloat = 0) {
        self.notch = notch
        let notchWidth = notch.size?.width ?? Self.fallbackNotchWidth
        let width = max(notchWidth * 1.06, 210) - 11
        // One extra point below the hardware notch keeps its lower edge covered on every scale.
        let height = notch.size.map { max(Self.minimumHeight, ceil($0.height) + 1) } ?? Self.minimumHeight
        rest = NSRect(x: (canvasWidth - width) / 2, y: canvasTop - height, width: width, height: height)
        if notch.hasNotch {
            hover = NSRect(x: rest.minX - 7, y: rest.minY - 4, width: rest.width + 14, height: rest.height + 4)
        } else {
            let peekWidth = (rest.width * Self.peekWidthRatio).rounded()
            hover = NSRect(x: rest.midX - peekWidth / 2, y: canvasTop - Self.peekHeight,
                           width: peekWidth, height: Self.peekHeight)
        }
        let depth = max(menuBarHeight, Self.minimumRevealDepth)
        // The pointer can report the top row at canvasTop itself; include it.
        openZone = NSRect(x: rest.minX - Self.openMargin, y: canvasTop - depth,
                          width: rest.width + Self.openMargin * 2, height: depth + 1)
        let peekDepth = depth + Self.peekExtraDepth
        peekZone = NSRect(x: rest.minX - Self.peekMargin, y: canvasTop - peekDepth,
                          width: rest.width + Self.peekMargin * 2, height: peekDepth + 1)
    }

    /// 同一形状移到屏幕顶边之外，作为无刘海时收起的终点和展开的起点。
    func retracted(_ shape: NSRect) -> NSRect {
        NSRect(x: shape.minX, y: rest.maxY + 1, width: shape.width, height: shape.height)
    }

    /// 休息态实际显示的轮廓：有刘海时包住刘海；无刘海时收成贴住屏幕顶边的零高度形状，
    /// 展开 / 收起仍能从顶边伸缩，静置时不留下任何黑块。
    var restVisible: NSRect {
        notch.hasNotch ? rest : NSRect(x: rest.minX, y: rest.maxY, width: rest.width, height: 0)
    }

    /// 点（画布坐标）是否已贴到屏幕顶边。
    func isAtTopEdge(_ point: NSPoint) -> Bool {
        openZone.contains(point) && point.y >= rest.maxY - Self.edgeDepth
    }
}
