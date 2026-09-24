# 阶段 2AO：内置屏幕 Space 跟随试验（隔离预览）

日期：2026-09-25（Asia/Kuala_Lumpur）

## 范围

用户要求在内置屏幕实测当前单实例 Scene 焦点跟随预览。此次仅有显示器 1；验证对象是同一块内置屏幕上的 Space 切换、短时运行与自动清理。阶段 2AN 新增的“旧屏继续播放 1.5 秒再跨屏移动”需要第二块屏幕，此次无法触发或验证。正式 Scene 播放入口仍关闭。

## 试验前状态

- 桥接器 `--selftest` 与 `--verify-follow-runtime dist/MirageFocusFollowRuntime` 通过。
- 只读焦点诊断报告 `connected=[1] selected=1 source=frontmostWindow`。
- `phonto-wall status` 显示未运行、自动轮播未开启；无旧 `SceneWallpaper` 或 `MirageSceneBridgeProbe` 进程。
- 实际样本 `3483456356/scene.pkg` 为 65,349,890 字节普通文件。

## 60 秒运行

在用户本次请求下，以 `--follow-trial ... 1 --consent` 启动隔离运行目录。探针输出 `trial: activated on display 1; stopping after 60 seconds`，60 秒后输出 `trial: stopped cleanly`，退出码 0。结束后再次检查无 SceneWallpaper 或桥接器进程；phonto 仍未运行、自动轮播未开启。

渲染子进程每 5 秒采样一次，共 13 个样本。第 5-60 秒 `%CPU` 样本均值 21.44%（一个 CPU 核心为 100%）；第 0-60 秒 CPU 时间增加 12.69 秒，约等于单核 21.15%。第 15-60 秒 RSS 样本均值 109.62 MiB，启动瞬间 180.4 MiB，结束时 102.0 MiB。原始日志在 `/private/tmp/mirage-follow-internal-1m.log`，不纳入 Git。单次采样不能证明省电，也未测持续实显帧率、GPU 或五分钟稳定性。

## 目视验收与边界

用户确认切换后 Scene 画面跟随、图标可点击、试验结束无残留；但在切换动画过程中，短暂变成旧桌面。这是本轮新增的可见缺陷，不能将“Space 切换过程连续显示 Scene”判为通过。静态代码中，焦点跟随窗口同时设置 [`CanJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces) 与 [`Stationary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary)；Apple 文档仅分别保证“可出现在所有 Space”和“Mission Control 不影响窗口”，并未保证系统切换动画中持续合成。旧桌面短暂出现的确切窗口层/动画原因待独立验证。跨屏焦点移动和 1.5 秒保持时序仍待第二块屏幕与新的实机试验。
