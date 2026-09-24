# WE 场景阶段 2X：隔离可见画面预览（实机验收完成）

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

## 真实窗口验收（2026-09-24）

在独立开发应用中，使用系统文件选择器手选真实样本 `3483456356/scene.pkg`，输入包内相对纹理路径 `materials/阿罗娜 人物.tex`。普通窗口的黑色显示区先加载，再显示人物、樱花与背景的受限合成画面；连续两张窗口截图中人物头发、眼睛和下方衣饰位置有可见差异。窗口文案始终标为「实验画面」「非桌面壁纸」。同一轮连续截图的 PNG 数据也发生变化，但这只是辅助证据，动态结论以可见画面差异和帧接收条件共同支撑。

程序只在交付至少两帧且至少两种不同 RGBA 像素帧后才以成功路径退出；这轮 5 秒后应用清单显示 `isRunning=false`，手动关闭的另一轮也显示退出。原桌面没有被实验应用接管：源码中只有普通层级窗口，不调用 phonto 或系统壁纸设置；本轮未另做桌面背景的逐帧拍摄，因此「桌面未变化」依据操作范围与代码路径，不是新的桌面视觉验收。

**阶段结论：受限 Scene 动态画面已在普通应用窗口实机验收；仍不是桌面动态 Scene 壁纸。** `desktopScenePlayable=false`、`faithfulSceneRendering=false` 保持不变。接下来按 `WE场景-阶段2Y桌面承载边界设计.md` 先准备桌面层级与生命周期的独立试验，不把此窗口直接接入正式播放按钮。
