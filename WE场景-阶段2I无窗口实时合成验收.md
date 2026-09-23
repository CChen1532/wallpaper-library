# Scene 阶段 2I：无窗口实时帧受限合成

日期：2026-09-24。状态：**无窗口、短时、受限 scene 画面合成已验证；桌面动态壁纸未验证**。前置版本 `4685783` / `scene-stage2h-preview.1`；本阶段提交与预览标签以 Git 日志为准。

## 本阶段实现

- `WESceneRealtimeSceneSession` 复用经校验的包与 `AVPlayerItemVideoOutput` 视频会话，把新到的 RGBA 帧注入既有 scene 合成器。视频路径按包内资源定位，不写原素材；只在内存合成 RGBA，调用方可选择导出检查。
- 诊断将无窗口视频帧标为 `frameMode=windowlessRealtimeProbe`、`windowlessVideoFrame`，与旧的离线取帧分开。单 pass 常规 colorkey 继续按 CPU 近似公式处理；其它效果、脚本、粒子、混合模式限制保持明确。每帧 `playable=false`、`faithful=false`。
- CLI `realtime-scene-probe <scene.pkg> <materials/name.tex> <seconds> <outdir> [poll-hz] [max-edge]` 限制运行 0.5-3 秒、2-10 Hz 轮询、最长边不超过 960；全新输出目录，先写私有暂存目录后整体移动。每帧有 PNG/诊断 JSON，总清单记录视频时间、不同画面数以及 `desktopAttached=false`。

## 验证

- `bash scripts/check-scene.sh`：138 项自测通过、0 失败。新增无窗口帧诊断与不可播放断言；既有合成、抠色、离线帧和视频输出检查保持通过。
- 真实样本 `3483456356`：2 秒、5 Hz、640 像素无窗口探针输出 **5 帧、5 种不同合成画面**；显示时间 0、约0.35、0.8、1.25、1.7 秒。首尾 PNG 目视可见人物在樱花背景上有细微运动，黄色背景未出现。结果仅在 `/private/tmp/wescene-stage2e.9NH1bN/realtime-scene-348/`，不进入 Git。
- 首帧诊断确认 `windowlessRealtimeProbe`、`windowlessVideoFrame`、`colorKeyApproximation`、`playable=false`、`faithful=false`；完成后没有遗留 `wescene-video-*` 临时提取目录。
- 这不是稳定 5 fps 或 30/60 fps 的性能证明；CPU 合成和诊断导出会占用时间，也没有显示器同步、暂停恢复、循环或桌面层窗口。真实样本其它效果与缺失模型仍限制画面忠实度。原素材、桌面背景、UI 均未更改。

## 下一阶段

在同一无窗口运行时测暂停/恢复与片尾循环，记录真实输出帧时间和丢帧；优化复用静态资源，评估 CPU/GPU 路线。只有受控合成和资源生命周期足够稳定后，才单独实现桌面层挂载、退出恢复和真实视觉验收。当前不能开放“设为动态 scene 壁纸”。
