# 阶段 2AR：桌面层级 Space 过渡候选（隔离预览）

日期：2026-09-25（Asia/Kuala_Lumpur）

## 依据与边界

2AQ 的 Managed 变体在 Mission Control 中被抽为带标题的普通窗口，已判失败。保留 2AM/2AN 使用的 `CanJoinAllSpaces | Stationary | IgnoresCycle` 行为，避免再次让 Scene 参与普通窗口总览。2AO 在此行为下切换完成后画面和图标正常，但切换动画会短暂露出旧系统桌面。

本机只读 WindowServer 层级检查：`kCGDesktopWindowLevelKey=-2147483623`，`kCGDesktopIconWindowLevelKey=-2147483603`；所测系统壁纸窗口在 `-2147483625`，Dock 桌面背景窗口在 `-2147483624`，Finder 图标层在 `-2147483603`。此前 Scene 使用图标层减 1，即 `-2147483604`。Apple 的 [desktop 窗口层级说明](https://developer.apple.com/documentation/swiftui/windowlevel/desktop)把这类窗口描述为位于壁纸之上、其他内容之下。选择 `kCGDesktopWindowLevelKey` 是一个**单变量实测假设**：把 Scene 移近系统桌面背景，观察 Mission Control 是否更可能把它留在背景而不出现旧桌面。公开 API 并未保证第三方动态窗口会被纳入每个 Space 的背景快照，不能从层级数字推断修复。

## 隔离实现

新补丁 `patches/mirage-desktop-layer-follow.patch` 从固定 Mirage v1.1.4 的原焦点跟随补丁独立派生。它只把窗口创建、激活几何检查和跨屏移动前检查里的层级，从 `kCGDesktopIconWindowLevelKey - 1` 改为 `kCGDesktopWindowLevelKey`。`CanJoinAllSpaces | Stationary | IgnoresCycle`、忽略鼠标、单窗口/单渲染进程、跨屏1.5秒等待及60秒自动清理规则均不变。独立构建与运行目录分别为 `dist/MirageDesktopLayerSource` 和 `dist/MirageDesktopLayerRuntime`；旧 Stationary 目录和失败 Managed 目录不覆盖。

## 离屏验证

- 新补丁对固定上游 `git apply --check` 通过；构建和运行目录脚本 `bash -n` 通过。原焦点跟随及 Managed 构建的 `--check` 未回归。
- 新隔离源码完成 arm64 Release 全量构建，SceneWallpaper、Viewer、Saver 均生成。与原焦点跟随源码比较，仅上面三个层级表达式不同。
- `--verify-follow-runtime dist/MirageDesktopLayerRuntime` 与桥接器 `--selftest` 通过。隐藏、从未 `orderFront` 的 AppKit 窗口读回 `stationary=true`、`managed=false`、`allSpaces=true`、`ignoreMouse=true`、层级 `-2147483623`、`visible=false`。

上述检查没有创建桌面显示面，**不能证明** Scene 在真实桌面会压住系统壁纸、Mission Control 背景会显示 Scene、切换动画无旧桌面、图标安全或跨屏连续性。下次须获新的当次许可做一次有界内置屏实机复验，重点观察启动首帧、进入 Mission Control、切换到另一个 Space 并返回的动画全过程、图标及自动清理。若背景层级导致 Scene 不可见或图标异常，应立即保留原运行目录并停止采用此候选。正式 Scene 能力保持关闭。
