# 阶段 2AP：Space 切换动画旧桌面闪现的隔离修正预览

日期：2026-09-25（Asia/Kuala_Lumpur）

## 现场现象与假设

2AO 内置屏 60 秒试验中，用户确认切换完成后 Scene 跟随、图标能点击、退出无残留；但切换动画内短暂显示旧桌面。当前焦点跟随窗口设置 `CanJoinAllSpaces | Stationary | IgnoresCycle`。Apple 对 [`CanJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces) 的说明是窗口可出现在所有 Space；[`Stationary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary) 只说明 Mission Control 不影响窗口、保持静止；[`Managed`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/managed) 表示窗口参与 Mission Control 和 Spaces。这些公开说明未保证系统切换动画会如何合成桌面层窗口，因此“静止窗口未纳入过渡快照”目前是待实测假设，而非已定位的系统原因。

## 隔离改动

新补丁 `patches/mirage-space-transition-managed.patch` 只改变焦点跟随模式的窗口集合行为：使用 `CanJoinAllSpaces | Managed | IgnoresCycle`，使它参与 Space/Mission Control 过渡；非跟随模式仍使用 `Stationary | IgnoresCycle`。窗口层级仍为桌面图标层减 1，仍忽略鼠标事件；单渲染器、`--consent`、60 秒自动停止、运行中显示器移动与 1.5 秒焦点交接逻辑没有改变。

`scripts/build-mirage-focus-follow-source.sh --build --managed-transition` 从固定 v1.1.4 源码建立被忽略的 `dist/MirageSpaceTransitionSource` 并应用此独立补丁。`scripts/prepare-mirage-source-runtime.sh --managed-transition` 生成独立的 `dist/MirageSpaceTransitionRuntime`。先前 `MirageFocusFollowSource` / `MirageFocusFollowRuntime` 保留，便于回退；固定上游子模块不修改。

## 离屏验证与实机门槛

- `bash -n` 两个脚本、补丁对上游 `git apply --check` 均通过；旧焦点跟随构建 `--check` 仍通过。
- 新隔离源码 arm64 Release 完整构建成功，SceneWallpaper、Viewer、Saver 三产物生成。新旧宿主源码比较仅有上述 `collectionBehavior` 分支差异。
- 隐藏的 32×32 AppKit 窗口从未 `orderFront`，只用于检查公开属性组合：读回 `managed=true`、`allSpaces=true`、`ignoreMouse=true`、层级 `-2147483604`、`visible=false`。这证明本机 AppKit 接受标志组合，不证明切换动画呈现。
- 桥接器 `--selftest` 通过，`--verify-follow-runtime dist/MirageSpaceTransitionRuntime` 通过。上述验证没有创建桌面窗口，也不能证明切换动画已消除旧桌面闪现或 Mission Control 图标安全。

用户暂缓实机试验。下次须获得新的当次许可，在当前内置屏做一次有界桌面试验：至少切换 Space 并返回，重点观察**切换动画全过程**、画面持续性、图标点击与退出清理。若动画仍露出旧桌面，不能继续宣称本改动有效；需进一步区分窗口是否在过渡时被移出合成、旧系统壁纸快照层是否覆盖它等可能性。正式 Scene 播放入口继续关闭，跨屏 1.5 秒保持仍未实测。
