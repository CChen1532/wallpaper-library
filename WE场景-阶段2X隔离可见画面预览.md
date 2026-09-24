# WE 场景阶段 2X：隔离可见画面预览（待实机验收）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 本阶段已实现

新增独立的开发测试应用 `WESceneVisibleProbe`，不出现在正式「视频壁纸」的场景播放入口。它手动选择单个 `scene.pkg` 和包内视频纹理路径，使用阶段 2W 的单路帧交付器，把受限合成 RGBA 帧转换成普通层级 AppKit 窗口中的 `NSImage`。窗口标题和文案明确写出「实验画面」「非桌面壁纸」；未创建桌面底层窗口，也没有调用 phonto 或更改当前壁纸。

包要求非符号链接常规文件、≤64 MiB，读取后核对字节数。实验画面每次最多交付 5 秒、10 Hz、50 帧、最长边 640 像素；未取得至少两种不同像素帧会报失败。窗口关闭会请求取消并等待帧交付器的清理路径；正常/错误结束后关闭窗口与进程。现有单次解码或图像交付无法立即抢占，且加载包所需时间不包含在 5 秒画面交付限额内。

工具位于独立 SwiftPM 可执行目标；`scripts/build-visible-probe.sh` 构建和本地签名 `dist/WESceneVisibleProbe.app`。真实样本路径与纹理名没有硬编码到工具。`desktopScenePlayable=false`、`faithfulSceneRendering=false` 不变。

## 已完成的验证

| 检查 | 结果 |
|---|---|
| `bash scripts/check-visible-probe.sh` | Debug 编译、2×2 RGBA 红/绿/蓝/半透明像素的颜色、上下方向与透明度自检通过；短缓冲和超尺寸拒绝 |
| `bash scripts/build-visible-probe.sh`、`codesign --verify --deep --strict` | 独立测试应用 Release 构建和签名通过 |
| 打包二进制 `--selftest` | 受限 shell 中无输出退出 134；获准的非沙箱只读运行中自检通过。原因尚未定位，不把这项等同于窗口验收。 |
| `bash scripts/check-scene.sh`、`bash scripts/check.sh` | Scene 161 项、视频前端 39 项通过；均未启动桌面 scene |

## 待完成的实机验收

当前尚未临时启动测试窗口，也未捕获两个时间点的可见画面或验证自动关闭。已向用户请求本轮临时启动许可；获确认后再从独立应用手选真实场景、目视检查画面运动与限制文案，并确认结束后进程退出、原桌面不变。**因此本阶段只能标记为预览，不能声称可见动态场景已实机验收，更不能声称桌面 Scene 播放。**

下一步在获准验收后，若发现窗口转换/停止问题则先修复并另行提交；之后再设计真正桌面层级、Space/显示器/睡眠生命周期与 phonto 共存的独立试验。
