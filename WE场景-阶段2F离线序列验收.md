# Scene 阶段 2F：有界离线序列与视频会话复用

日期：2026-09-24。状态：**离线序列预览**，不是按屏幕节奏播放的 scene 运行时，也没有修改桌面背景。前置版本 `f7e3ef6` / `scene-stage2e-preview.1`；本阶段提交与标签以 Git 日志为准。

## 本阶段实现

- `SceneVideoTextureSession` 在一次会话内只提取一次包内 MP4、校验单视频轨/尺寸/时长，复用 `AVAssetImageGenerator` 按需取帧，并在会话释放时清理临时 MP4。旧单帧 API 保持可用；新的 `WESceneOfflineFrameSession` 复用同一包与视频会话导出多帧。
- `WESceneOfflineTimeline` 将有限帧序号映射为视频源时间，限定 1-60 fps、0-120 帧号；到视频时长后取余循环，不钳制或外推越界时间。它只计算时间，不驱动屏幕刷新，也未实现暂停/恢复。
- CLI `sequence <scene.pkg> <materials/name.tex> <fps> <count> <outdir> [max-edge]` 导出 1-120 帧 PNG、每帧诊断 JSON 和总清单。要求全新输出目录；先写私有临时目录，全部成功后才移动到目标位置。清单显式标记 `frameMode=offlineSequence`、`playable=false`、`faithful=false`。
- 序列最长边默认 960、上限 1600。内存和每帧合成仍使用现有边界；不会执行脚本、音频或未知效果。

## 验证与边界

- `bash scripts/check-scene.sh`：126 项合成自测通过、0 失败。新增时间循环、非整帧余量、非法帧率/时长、帧号边界。
- `swift build --disable-sandbox --target WESceneCore` 通过；`bash scripts/check.sh` 视频前端 34 项通过。
- 真实样本 `3483456356`：在临时目录导出 2 fps、3 帧、640 px 序列，清单记录请求和实际时间均为 0、0.5、1 秒；三张 PNG 摘要不同。输出在 `/private/tmp/wescene-stage2e.9NH1bN/seq-348/`，不纳入 Git。旧 `frame` 命令在重构后仍可输出与2E相同 SHA-256 的 0 秒 960×540 画面。
- 已有目标目录时拒绝覆盖；非法 0 fps 在读取媒体前退出且无输出目录。完成后未留下 `wescene-video-*` 临时提取目录。
- 真实 AVFoundation 解码仍需当前获准的本机执行环境；默认工具沙箱对该素材报 `Cannot Decode`。未验证签名应用权限、长时间运行、暂停恢复、实时帧率或桌面视觉运动。

## 下一阶段

研究可暂停/恢复的单调时钟和真实视频输出帧同步。Apple 的 [按时间生成图像 API](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image%28at%3A%29)适合当前离线检查；后续实时显示应评估 [AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)，不能把离线序列直接当作桌面播放器。再单独设计桌面层挂载与 UI 后端能力开关。
