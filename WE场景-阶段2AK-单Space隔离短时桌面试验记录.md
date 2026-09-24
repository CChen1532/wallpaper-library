# WE 场景阶段 2AK：单 Space 隔离变体短时桌面试验（预览）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 当次范围与结果

用户仅授权对阶段 2AJ 的隔离 Mirage 变体做一次约 5 秒桌面试验，不包括五分钟长时播放。试验前，`phonto-wall status` 为未运行／轮播未开启；外接屏 测试显示器 的当前显示器 ID 为 3；真实样本 `3483456356/scene.pkg` 为 65,349,890 字节；`MirageSceneBridgeProbe --verify-runtime dist/MirageSingleSpaceRuntime` 和隔离源码构建检查通过，进程列表无 Mirage、phonto 或旧试验进程。未改动原场景素材或系统壁纸设置。

在正常桌面媒体环境中运行一次 `MirageSceneBridgeProbe --trial dist/MirageSingleSpaceRuntime <scene.pkg> 3 --consent`。探针收到 `activated on display 3`，约 5 秒后打印 `stopped cleanly`，退出码 0。结束后进程列表无 SceneWallpaper、桥接器或旧试验进程，phonto 仍为未运行／轮播未开启。用户确认人物场景持续运动、画质和桌面图标正常。

用户本次没有明确切换到另一桌面，故**不能把补丁去掉 `CanJoinAllSpaces` 的源码事实等同于单 Space 实际隔离验收**；也未独立目视确认停播后的桌面视觉残留。自动退出与无进程残留是本次的机器侧证据。此试验没有运行五分钟、测试睡眠／热插拔／多屏／运行中 phonto 共存，也不证明完整 Wallpaper Engine 效果兼容。

## 后续门槛

保留 `desktopScenePlayable=false`、`faithfulSceneRendering=false`，正式“设为动态壁纸”入口不接入这个开发试验变体。下一步可在不启动桌面的情况下，为独立桥接探针设计和验证有界长时模式、无帧看门狗及强制清理；真正五分钟桌面验收仍须另获当次授权，并实际确认画面、图标、时间、停止与资源占用。所有 Space 适配继续排在长时稳定播放之后；若在正式长时试验前需要证明单 Space 行为，另行申请短时跨 Space 目视试验。
