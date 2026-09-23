# Scene 阶段 2H：静音无窗口实时视频输出探针

日期：2026-09-24。状态：**真实视频帧输出已验证，scene/桌面播放未验证**。前置版本 `e60b326` / `scene-stage2g-preview.1`；本阶段提交与预览标签以 Git 日志为准。

## 本阶段实现

- `WESceneRealtimeVideoSession` 使用已有受限 TEX/MP4 解析与临时文件生命周期，创建静音、无窗口的 `AVPlayer` 和 `AVPlayerItemVideoOutput`。按主机时间查询新视频帧；有新帧才读取，关闭时暂停并移除 player item。
- 输出明确要求 32 位 BGRA、尺寸与 TEX 相同；按实际行跨度转换为 RGBA，拒绝未知格式、错误尺寸或无效像素地址。该 RGBA 帧仅返回内存，尚未进入 scene 图层合成器。
- CLI `realtime-probe <scene.pkg> <materials/name.tex> <seconds> [poll-hz]` 限定 0.5-5 秒、2-30 Hz 轮询，输出请求项目时间、显示帧时间、像素摘要和帧数的诊断 JSON；`playableScene=false`、`desktopAttached=false`。它不是播放器入口，不设置桌面壁纸。

## 验证

- `bash scripts/check-scene.sh`：137 项合成自测通过、0 失败；新增 BGRA 行跨度/RGBA通道转换、尺寸与像素格式拒绝。合成 CVPixelBuffer 创建时当前工具沙箱出现系统 `IOSurface` 警告，但测试返回成功。
- 真实样本 `3483456356` 的 `materials/阿罗娜 人物.tex`：2 秒、5 Hz 的静音无窗口探针得到 **8 个不同帧摘要**，显示帧时间从 0 前进到约 1.62 秒，尺寸均为 2324×2474。每次轮询不保证都有新帧；本次结果只是有界短跑，不代表稳定目标帧率或长期播放。
- 输出会话退出后没有遗留 `wescene-video-*` 临时提取目录。原素材、当前桌面壁纸和 UI 均未修改。默认工具沙箱的 AVFoundation 解码仍有限制，真实样本验证在获准的本机执行环境完成。
- `swift build --disable-sandbox --target WESceneCore` 与 `bash scripts/check.sh` 的最终结果见总计划验证记录；不把编译成功或多帧摘要冒充桌面 scene 运动验收。

## 下一阶段

把新的实时 RGBA 帧接入受限 scene 合成器，在受控、非桌面输出中检查人物抠色与背景同步；再测暂停/恢复、循环、丢帧和资源释放。只有单独通过桌面窗口挂载与实际视觉运动验收后，才考虑给 UI 开放“设为动态 scene 壁纸”。

Apple 的 [AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)提供视频帧输出能力；这里仅验证其本机短时探针用途，不推断其它 Wallpaper Engine 效果兼容。
