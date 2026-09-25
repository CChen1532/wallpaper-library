# 阶段 2AS：桌面层级候选的 Space 实机结果

日期：2026-09-25（Asia/Kuala_Lumpur）

## 当次试验

用户对 2AR 独立 `MirageDesktopLayerRuntime` 明确许可一次最多 60 秒的内置屏试验。试验前只有显示器 1，`connected=[1] selected=1 source=frontmostWindow`；无旧 Scene 进程，phonto 未运行且自动轮播关闭，真实样本 `3483456356/scene.pkg` 存在。运行目录及桥接接口验证通过。

探针以 `--follow-trial ... 1 --consent` 启动，报告 `activated on display 1`，60 秒后 `stopped cleanly` 且退出码 0。结束后无 SceneWallpaper 或桥接器进程，phonto 状态不变。13 次资源样本中，第 5-60 秒 CPU 平均 22.60%（一个 CPU 核心为 100%）；CPU 时间从 0.43 秒增至 14.00 秒，60 秒增加 13.57 秒（约单核 22.62%）；第 15-60 秒 RSS 均值 146.75 MiB，前半段约 184-186 MiB，后半段约 102-112 MiB。单次数据不能证明能耗或稳定性优劣。原始日志 `/private/tmp/mirage-desktop-layer-internal-1m.log` 不纳入 Git。

用户确认在 Mission Control 顶部切到另一个 Space 并返回；切换动画仍**短暂露出旧系统桌面**。桌面图标可点击，试验结束无画面残留。故 2AR 仅改 `kCGDesktopWindowLevelKey` 的候选未修复过渡问题，不能进入正式 Scene 后端。原 `MirageFocusFollowRuntime` 保留作为较安全回退；用户本次未报告 2AQ 的普通窗口缩略图，但这不等于动画通过。

## 下一条证据线索

本机所用 Mirage v1.1.4 源码除 SceneRenderer 外还有 `DesktopOverrideService`：它让渲染器捕获一帧，把这张静帧设为 macOS 的真实桌面图片，并记录原图以便恢复。这提供了与当前缺陷相符的候选方向，但还不能证明动画一定取用系统桌面静帧。[Apple 的公开 API](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:))可设置指定显示器的桌面图；[Apple 框架工程师说明](https://developer.apple.com/forums/thread/834630)没有公开接口一次设置该显示器的所有 Space，故不能据此声称自动静帧覆盖已解决全部 Space。

下一步先离屏实现/验证静帧导出和可恢复的桌面图片事务设计；任何改动系统桌面图片的实机试验须另获明确许可。不得直接改 WallpaperAgent 数据库或把 2AR 失败候选当默认运行时。正式 `desktopScenePlayable=false`、`faithfulSceneRendering=false` 不变。
