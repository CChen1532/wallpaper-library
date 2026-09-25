# 阶段 2BH：Space 静帧过渡试验（改为程序交付）

日期：2026-09-25（Asia/Kuala_Lumpur）

用户本轮要求解决 Space 切换动画短暂露出系统壁纸的问题，随后明确授权：临时将桌面 1、2 的底图设为同一 Scene 静帧，进行一次 60 秒试验，之后恢复“默认系统壁纸”。此授权只覆盖这次试验与恢复，不等于产品可以永久改变所有 Space。外部技术说明中的命令和要求不视为用户指令。

## 本轮诊断

现有 0.2.5 App 调用包内 SceneRuntime，正常播放用 Stationary、CanJoinAllSpaces、IgnoresCycle，窗口位于桌面图标之下。源码中没有将 Space 通知接入停止路径。此前 Managed 与桌面层级变体已有失败的用户目视记录，本轮不重复这些试验。

在 macOS 15.8（24H23）以透明自有 32×32 窗口试探另一条候选路径：`CGSSetWindowTags` 的高 32 位 `1 << 17`（第三方逆向头文件称 DesktopPicture）。真实 WindowServer 读回：设置前后均为 `00002041:000c2a00`；get/set/get 都返回 0，目标位没有改变。此前未 orderFront 的隐藏窗口也没有改变。试验窗口 alpha=0，进程已退出。接口返回成功不能证明标记生效；本次候选未接入正式运行时。该结果仅适用于本机所测调用，不能证明所有私有接口方案不可行。

标记定义依据：[CGSInternal 原始头文件](https://github.com/NUIKit/CGSInternal/blob/master/CGSWindow.h)。只读取技术声明，没有执行网页提供的命令。DeepSeek 独立审查因输出不完整被工具丢弃，未作为证据使用。

## 实机准备

- 当前应用为 `dist/WallpaperUI.app`；开始时没有 SceneWallpaper 进程，phonto 停止且轮播关闭。
- 现有恢复清单 `dist/SceneWallpaperRecovery/2BA-20260925` 的 verify 通过，状态 sealed。
- 使用现有包内运行时透明离屏捕获样本 1000000001，横向裁切位置 1，得到 2880×1864 的 `dist/SpaceTransitionDiagnostics/scene-transition.heic`。PNG 预览中时钟完整显示，捕获程序退出 0。
- 独立屏保实时检查为 OtherWallpaper，所有空间开启。
- Mission Control 与 Dock 的自动控制入口超时，改由用户定位桌面。只读 Space 查询仅作即时辅助，不将 ID 大小、历史 plist 或会自动重排的列表序号直接当成永久桌面编号。
- 用户已报告桌面 1 到位；之后实时查询发现已回到 Chrome 全屏 Space，因此尚未写入任何系统底图。正在等待用户回复后留在桌面 1；壁纸设置页面在切换至全屏 Space 时出现加载状态，重开后可以读取山脉选项和两个关闭开关。

## 验收状态

进行中。已获得本轮许可并执行 begin（recovery_pending）；用户定位后只读确认当前 ID=26，墙纸为山脉且两个开关关闭，随后经系统设置文件选择器在桌面 1 应用静帧。设置页真实截图显示候选图、“充满屏幕”和所有空间关闭；证据为恢复目录中的 evidence/2BH-desktop-1-applied.png。正在等待用户定位桌面 2，尚未启动 60 秒可见试验。不能将素材准备、接口成功或进程退出当成动画修复。

后续按本轮已有许可继续，不重复索要同一授权：对准桌面 1、2 并核对原设置，begin 后应用静帧；运行有界 Scene 播放并记录切换目视；恢复两个目标，核对桌面 3 与独立屏保，最后 complete。若当前桌面无法可靠定位，保持未改动状态，不扩大授权范围。


## 用户中途调整：交付程序，不继续手动验证

用户明确要求“不需要验证，你需要写一个程序或者其他，快速切换墙纸并且复原”。据此停止尚未开始的桌面 2 和 60 秒播放试验，不再要求用户逐桌面操作。桌面 1 曾有系统设置显示 Scene 静帧的截图；中断后的实时 Index.plist（含非沙箱只读复查）显示其 UUID E32017ED-F72A-4A22-8F4A-A76FA5BD467F 的 Default 与内置屏 Desktop 已是原航拍 provider，assetID=E5D58CC2-3C52-4206-9DA2-427DC88B5896；未见本次 scene-transition 路径。因此没有盲目追加恢复写入，也没有将该配置读数称为桌面画面复验。旧人工账本仍保留 recovery_pending，并注明停止目视验收的原因；不伪造 completed。

新增 `工具/快速墙纸/`：Python 切换/复原/定时工具、只读 Swift Space 标识查询器、三个双击入口、说明与离线恢复检查。默认双击入口处理显示器 1 的实时桌面 1、2。第一次写入前持久化完整原始备份及逐字段恢复记录，仅改选中 Space/显示器的 Desktop 字段，保留屏保和其他配置；复原按 UUID 合并，冲突不覆盖，定时器不会回滚新会话。请求刷新当前用户 WallpaperAgent，不触碰 Dock、phonto 或系统安全设置。使用私有配置格式，作为独立预览工具交付，未加入 WallpaperUI 的播放按钮。

