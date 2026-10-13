# 浮窗捏合失效与延迟诊断

本地记录：2026-10-13，macOS 27.0.1。以下区分已观察到的阻塞位置与尚未确认的触发原因；未作为正式修复发布。既有动效曲线、时长及缩放计算保持不变。

## 捏合停止送达

基线浮窗在输入或等待一段时间后，双指捏合失效，边缘拖动仍正常。打开设置、关闭设置并回点笔记可暂时恢复。其他应用的捏合正常。

诊断版在 `NSApplication.sendEvent`、本地监视器及面板 `sendEvent` 分层记录。失效时，应用入口也不再收到 magnify；滚动事件仍到达。面板处于展开状态，故障发生时 key/active 为真，拖拽、边缘缩放与缩放计时器均未占用。scrollWheel 的 mayBegin/cancelled 不能单独证明捏合已经被系统识别。

三个对照的结果：

- 原 resize handler 只执行一次，处理后继续转发原 magnify 事件，仍会失效。字体与正文 magnification 未变；单纯截断分发不足以解释问题。
- 原生视图树每五秒只读采样，健康与失效期间均未见持续 began/changed 的 recognizer 残留。实际树未触及 128 个 view 上限；无法排除瞬时竞争或未公开的路由状态。
- 在新实例初始化时移除 `.nonactivatingPanel`，保留正文、转发方式、探针及动效，其后约二十分钟多轮捏合仍能投递，用户报告暂未失效。支持继续检查非激活面板路径，但尚未完成长期验证；点击激活及跨应用焦点行为也需要回归。未在存活窗口上切换此 bit。

滚动容器内置的 `NSMagnificationGestureRecognizer` 设置 `delaysMagnificationEvents=true` 是该类的正常行为，不能据此判断识别器异常。[Apple 类说明](https://developer.apple.com/documentation/appkit/nsmagnificationgesturerecognizer)

## 延迟中的主线程阻塞

激活属性对照仍有明显延迟。完整 `displayResize` 自计时通常约 4–10 ms，包含窗口 origin 更新及视口布局；记录到的 magnify 事件年龄最高约 3.3 s。事件年龄是应用收到事件时距离 `NSEvent.timestamp` 的时间，不能等同于物理手势识别耗时。

分段线程采样确认了主要阻塞路径：

`RunLoop / DisplayLink → CA::Transaction::flush/commit → CABackingStoreSynchronize → CA::Render::Context::wait_for_synchronize → Mach IPC`

这部分发生在后续画面提交阶段，不包含在 `displayResize` 自计时中。17:13:08 的一秒采样段中，主线程 102/148 个样本处于渲染同步等待，同期记录事件年龄 910 ms；下一段为 70/161，事件年龄 1328 ms。已经确认延迟期间存在显著的主线程画面缓冲同步等待，不能将整个 nextEvent / RunLoop 调用树都算作空闲。

采样段之间有约 0.4–0.7 s 空档，比例是样本占比，不是精确持续时间。高同步占比不必然伴随高事件年龄，也未证明全部延迟来自该路径。具体哪个 layer 触发同步、为何渲染服务需要等待，仍待定位。当前内容量下的文字布局耗时未解释主要等待；大文档标题列表的扩展性瓶颈应另行处理。

## 后续验证边界

下一步应定位缩放期间的 backing-store 重绘与提交，检查视图/图层失效范围及刷新调度，保留现有视觉与动效。窗口激活属性的稳定性与渲染延迟分别验收，不能以其中一项改善替代另一项。

专用构建参数、隐私字段与日志语义见仓库 README。诊断开关、原生快照及构造对照均不进入普通构建；本地自动测试验证几何、编辑状态及日志边界，不能替代真实触控板与长期使用验收。
