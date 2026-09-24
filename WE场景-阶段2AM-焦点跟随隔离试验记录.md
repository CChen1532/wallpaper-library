# 阶段 2AM：单实例焦点跟随 Space 与显示器（隔离预览）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 目标与机制

用户要求 Scene 壁纸跟随正在查看的 Space，并进一步跟随焦点跨显示器移动，以免为每个桌面或屏幕开独立渲染实例。本阶段保留**一个 SceneWallpaper 子进程、一扇桌面层窗口**。独立源码变体在显式 `--follow-focus` 下允许该窗口加入当前显示器的所有 Space；同一时刻仍只渲染一份场景。跨屏时，桥接探针每 250 毫秒读一次前台应用的普通窗口位置，找不到窗口时回退到鼠标所在屏；同一新目标连续出现两次才发送 `moveDisplay`。渲染器先隐藏旧位置、更新目标显示器和画布尺寸，在新帧通过原有几何检查后才重新显示。目标未知时保持现状；显示器断开或移动失败时停止有界试验。

AppKit 的 [`canJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces) 允许一扇窗口出现在各 Space；[`moveToActiveSpace`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/movetoactivespace) 的语义是窗口**成为活动窗口时**移至活动 Space，而本项目的桌面窗口不取得键盘焦点，故没有把它当作自动跟随手段。前台窗口几何使用公开 WindowServer 列表；没有使用私有 Space ID API，也没有请求辅助功能或屏幕录制权限。若系统不提供足够窗口信息，鼠标屏幕是启发式回退，不能保证与键盘焦点完全一致。

新补丁 `patches/mirage-focus-follow.patch` 只应用于被 Git 忽略的 `dist/MirageFocusFollowSource`；固定 v1.1.4 子模块和已通过单 Space 试验的旧变体不变。新的 `--follow-trial` 仍要求 `--consent`、真实 `scene.pkg`、phonto 停止，最多 60 秒后自动清理；正式 Scene 播放入口和能力标记不变。窗口仍处于桌面图标层之下、忽略鼠标事件，并在每次新帧显露前复核层级与几何。此前另一独立探针使用跨 Space 标志时出现过图标异常，因此源码配置和离屏自检不能代替实机图标检查。

## 构建与无桌面验证

- 固定 Mirage v1.1.4 的隔离源码完整 arm64 构建成功；渲染器、Viewer、Saver 三个目标生成。补丁可反向匹配，改动限定于桌面宿主与 SceneWallpaper 的控制通道。
- 桥接器 Release 构建、`--selftest` 通过：假渲染器移动命令与回执、前台窗口优先于鼠标、鼠标回退、两次样本消抖、生命周期失败和清理均覆盖。
- `--verify-follow-runtime dist/MirageFocusFollowRuntime` 通过；准备脚本拒绝覆盖已有目录。只读 `--focus-diagnose` 在正常桌面会话中报告 `connected=[3] selected=3 source=frontmostWindow`，表明本轮只有显示器 3 可用，无法实测跨屏移动。

## 60 秒 Space 实机试验

用户仅允许在现有显示器试验 Space。启动前 `phonto-wall status` 为未运行、轮播未开启；无旧 Scene 进程；真实 `3483456356/scene.pkg` 是 65,349,890 字节普通文件。隔离版在显示器 3 激活，运行 60 秒后打印 `stopped cleanly`，退出码 0。结束后没有 SceneWallpaper 或桥接器进程，phonto 状态仍未运行且轮播未开启。

用户确认在 Mission Control 顶部实际选择另一个桌面并返回；新桌面 Scene 画面持续显示，图标能点击，结束后无残留。这证明**这台机器、当前单显示器、当次 Space 切换**的目视行为通过；没有跨屏实机证据，也没有覆盖全屏应用、睡眠或五分钟运行。

本次每 5 秒采集一次渲染子进程，共 13 个样本。第 5-60 秒 `%CPU` 样本均值约 20.0%（单核 100%）、累计 CPU 时间增加 11.93 秒／60 秒（约单核 19.9%）；第 15-60 秒 RSS 均值约 98.2 MiB，启动瞬间样本 174.7 MiB。原始日志在本机 `/private/tmp/mirage-follow-space-1m.log`，不纳入 Git。与 2AL 的约 12.8% 单核 CPU 时间相比，这轮数值更高；期间用户实际切换 Space，单次试验不能归因于窗口策略，也**不能宣称已降低 CPU、GPU 或耗电**。节省占用的已实现约束是“不按 Space 或显示器复制渲染进程”；持续实显 FPS、GPU 和整机能耗仍未测。

## 未完成的验收

当前仅检测到一块屏幕。跨屏焦点移动、不同分辨率重建、图标层级及返回原屏尚需第二块屏幕和新的当次实机试验。五分钟稳定性、phonto 共存、睡眠恢复和完整场景效果也仍待分项验证。`desktopScenePlayable=false`、`faithfulSceneRendering=false` 保持关闭。
