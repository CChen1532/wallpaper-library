# Scene 阶段 2L：实时合成静态纹理跨帧缓存

日期：2026-09-24。状态：**无窗口短时合成的资源复用与释放已验证**；桌面 scene 播放、稳定帧率和完整效果链仍未完成。前置版本 `5187044` / `scene-stage2k-preview.1`；本阶段提交与预览标签以 Git 日志为准。

## 实现

- `SceneCompositor` 接受调用方提供的受限 `TextureCache`；单帧/离线旧入口仍各自建立默认缓存。`WESceneRealtimeSceneSession` 在同一会话跨帧复用静态纹理，关闭时清空，并提供命中、未命中与驻留字节数的诊断统计。
- 视频 RGBA 帧始终按时间变化注入，不进入静态纹理缓存；缓存键仍基于 TEX 内容 SHA-256 与 mip 层级，受原有 128 MiB 总预算与单图边界限制。
- `realtime-scene-probe` 的总清单新增关闭前后缓存统计。没有声称每帧 scene JSON、图层结构、材质或效果计算已缓存；本阶段仅减少静态 TEX 解码重复工作。

## 验证

- `bash scripts/check-scene.sh`：141 项合成自测通过、0 失败。新增两次合成同一包时首次加载、后续命中、画面一致和清空驻留断言。
- 真实样本 `3483456356`：2 秒、5 Hz、640 像素无窗口探针导出 6 张不同画面；静态纹理缓存 **11 次未命中、67 次命中**，关闭前驻留 `47,969,904` 字节，关闭后 `0` 字节。结果仅在 `/private/tmp/wescene-stage2e.9NH1bN/realtime-cache-348/`，不纳入 Git。结束后未留 `wescene-video-*` 临时目录。
- `swift build --disable-sandbox --target WESceneCore` 与 `bash scripts/check.sh` 结果见总计划。相比上轮 2 秒探针的帧数有变化，但测试时序与系统负载不可控，不将单次帧数差解释为可靠的吞吐提升。
- 原 scene.pkg、桌面背景及 UI 均未更改。仍为 `windowlessRealtimeProbe`、`playable=false`、`faithful=false`。

## 下一阶段

做有界持续运行与帧交付统计，找出每帧 scene JSON/图层解析、CPU 抠色和像素拷贝的主要成本；再决定是否需要 GPU 合成。桌面层挂载、退出恢复、多显示器和真实视觉运动仍是独立验收关口。
