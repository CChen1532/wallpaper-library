# 阶段 2AU：不改系统壁纸时的 Space 过渡边界

日期：2026-09-25（Asia/Kuala_Lumpur）

## 用户决定与实际状态

用户暂不允许把当前或另一个 Space 的系统壁纸临时改为 Scene 静帧。此阶段只检查窗口行为说明及已有实机结果，没有更改系统壁纸、切换“在所有空间中显示”或启动新的桌面试验。2AT 导出的静帧仍只是离屏候选，不得自动应用。

## 窗口方案的证据

- 现用独立焦点跟随运行时使用 `CanJoinAllSpaces | Stationary`。Apple 对 [`Stationary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary) 的说明是窗口在 Mission Control 中保持静止；该说明没有保证 Space 切换动画的每一帧都持续显示窗口。2AO 和 2AS 的用户目视均报告过渡中短暂露出系统旧桌面，故实际验收优先于行为名称。
- 2AQ 将窗口改成 `Managed`，Mission Control 把 Scene 当成带蓝框标题的普通窗口缩略图；该变体不能作为桌面背景使用。2AR/2AS 只把窗口降到 `kCGDesktopWindowLevelKey`，仍露出系统旧桌面；继续调相近层级缺少证据。
- 本机 macOS SDK `AppKit.framework/Headers/NSWindow.h` 明确规定 `Managed`、`Transient`、`Stationary` 至多选一；若不指定，非普通窗口层级默认 `Transient`。Apple 的 [`Transient` 说明](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/transient)称其在 Mission Control 中隐藏。直接移除 `Stationary` 因而没有改善缩略图/过渡的文档依据，不进行重复实机试错。
- [`NSWindow.CollectionBehavior` 总览](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)列举窗口加入 Space、参与 Mission Control 和全屏的公开行为，没有提供把第三方窗口合成为系统静态桌面图片的选项。这是当前所查公开窗口接口的范围，**不是**对所有可能实现方式的不可行性证明。

## 执行决定

保留 2AM/2AO 所用的旧 `MirageFocusFollowRuntime` 作为隔离回退：Scene 在 Space 切换完成后跟随，图标可点且停止后无残留；过渡闪现仍是未修复缺陷。`MirageManagedFollowRuntime` 与 `MirageDesktopLayerRuntime` 不进入默认路径。正式 `desktopScenePlayable=false`、`faithfulSceneRendering=false` 不变。

暂停 2AT 的系统静帧替换试验，不读取或改写 WallpaperAgent 私有数据库，也不因为已有 HEIC 就改变用户设置。除非取得新的公开接口证据或先做出可离屏验证的不同方案，不再为相同窗口标志/层级安排真实桌面试验。若用户以后主动选择静帧背景路径，仍需重新记录各 Space 原设置并就那一次系统更改和桌面试验取得当次许可；用户当前的“暂不更改”不能解释成已有许可。

本轮只做文档检查。窗口 SDK 说明属于 API 预期；Mission Control 的真实表现以 2AO、2AQ、2AS 的用户目视记录为准。没有新画面验证，不能把缺陷标成已修复。
