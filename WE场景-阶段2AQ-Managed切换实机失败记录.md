# 阶段 2AQ：Managed 窗口 Space 切换实机失败

日期：2026-09-25（Asia/Kuala_Lumpur）

## 试验与结果

用户明确要求开始测试阶段 2AP 的独立 `MirageSpaceTransitionRuntime`。试验前，唯一内置显示器为 `connected=[1] selected=1 source=frontmostWindow`；phonto 未运行且轮播关闭，无旧 Scene 进程；样本 `3483456356/scene.pkg` 为 65,349,890 字节。桥接器自检、运行目录检查通过。

探针以 `--follow-trial ... 1 --consent` 在显示器 1 激活，60 秒后输出 `stopped cleanly`，退出码 0。结束后没有 `SceneWallpaper` 或桥接器进程，phonto 状态未改变。13 次资源采样中，第 5-60 秒 CPU 样本均值为单核 21.99%，CPU 时间增加 12.30 秒／60 秒（约单核 20.5%）；第 15-60 秒 RSS 样本均值 99.51 MiB。原始日志位于 `/private/tmp/mirage-managed-space-internal-1m.log`，不纳入 Git。

用户实际切换 Space 并返回，确认图标正常、结束无残留，但出现新的画面异常。用户截图显示 macOS Mission Control 将 `SceneRenderer Wallpaper` 作为带蓝色边框和标题的**普通窗口缩略图**居中显示，背后是系统静态山景壁纸，而非把 Scene 留在桌面背景。这证明该机器上的 `CanJoinAllSpaces | Managed` 候选不符合产品所需的桌面层行为；2AP 不能判为修复。截图仅用于本轮目视诊断，不复制进项目仓库。

## 处置与边界

原有 `MirageFocusFollowRuntime` 使用 `CanJoinAllSpaces | Stationary`，仍保留为较安全回退；本次测试窗口已自动清理，正式 Scene 能力仍关闭。独立 Managed 源码和补丁作为失败实验记录保留，后续试验不得默认采用。

此结果证明 **Managed 在 Mission Control 中被当作窗口**，并不直接证明 2AO 旧桌面闪现的全部原因。下一候选应保持 Stationary 与图标层安全约束，单独检查桌面窗口层级是否影响 Mission Control 背景合成；未经新的当次许可不启动桌面试验。跨屏 1.5 秒交接与五分钟稳定性仍未验收。
