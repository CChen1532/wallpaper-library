# 壁纸库

当前 UI：0.2.2 预览版。移除宣传语，采用简约原生画廊和独立设置页；设置与播放能力边界见 `UI-阶段2BD-简约界面与场景设置.md`。

macOS 14+ 原生 SwiftUI 壁纸前端，视频使用已有 phonto-wall，场景使用随应用打包的 Mirage Scene 运行时。打开 `dist/WallpaperUI.app` 即可使用。首次访问桌面目录时请允许系统权限请求。

## 构建与验证

```sh
bash scripts/build-app.sh
bash scripts/check.sh
bash scripts/check-scene-playback.sh
python3 scripts/check-scene-input.py
bash scripts/check.sh --live
bash scripts/check.sh --live --media
```

需要 Swift 5.9+ / Apple Command Line Tools，Swift UI 无外部包依赖；完整应用另需已准备好的 Mirage 运行时（GPLv3）。`--live` 读取真实素材并写入缩略图缓存，不改变播放状态。`--media` 在临时目录生成微型视频，测试导入、缓存、坏文件和移入废纸篓，不修改已有素材。构建产物与缓存不进入 Git；应用使用本地 ad-hoc 签名，尚未公证。

显式执行 `bash scripts/check-live-controls.sh` 会短暂播放和切换真实壁纸，并等待一分钟轮播触发。仅允许初始未播放、轮播关闭时运行；结束时恢复未播放、轮播关闭及原路径缓存。预计两分钟，不要与其他壁纸操作同时进行。

## 使用

- 侧栏“设置”或 ⌘, 打开设置：外观、鼠标总开关、点击响应、30／60／120 Hz采样、30／60 FPS、画面位置、跟随显示器、场景声音和音频响应。鼠标总开关同时控制视差／粒子／脚本收到的输入，具体效果取决于场景。
- 设置自动保存。外观立即生效；播放设置用于下次启动，也可点击“应用到当前场景”重启当前Scene。播放声音和音频响应默认关闭；音频响应可能需要系统录音权限。
- 单击视频卡片，在详情区点击“设为动态壁纸”，视频将在桌面背景播放；图片仅用于列表封面。底部提供上一段、随机、下一段。
- 界面使用 macOS 原生侧栏、工具栏和详情面板；View → 外观支持跟随系统、浅色、深色，不修改系统外观。自动轮播在侧栏独立设置页中。
- View 菜单支持紧凑窗口（980×680）和标准窗口（1200×800）。选中卡片后使用方向键切换选择，⌘Return 将选中的视频设为桌面壁纸。
- “停止”保留轮播，定时任务可能再次播放；“全部关闭”同时关闭轮播。
- 导入会复制 MP4 到已有素材目录，同名文件跳过并提示，不覆盖。
- 删除需要确认，文件移入废纸篓。若该文件正在播放或轮播开启，会先全部关闭。
- 预览缓存位于 `~/Library/Caches/WallpaperUI/Thumbnails`。
- 卡片展示帧率、时长和文件大小；设置页“关于 → 显示器与运行状态”按需读取诊断。
- 导入先验证视频，再通过临时文件完成复制，成功后才加入素材列表；大写 MP4 扩展名统一转成小写以匹配现有脚本。

## 当前限制

- 已修复现有脚本固定的 `--pause-on-battery`：电池供电下也播放视频。备份为 `~/.local/bin/phonto-wall.bak-before-continuous-20260923`，可恢复原文件以回滚；补丁存放于 `patches/`。这会增加电池耗电。
- 桌面视频播放与应用内预览不同；本版没有额外的应用内播放器。

- 本机脚本的 `rotate on` 分派只传递间隔，没有传递模式，因此 UI 暂仅开放随机轮播。该分派逻辑尚未修改。
- `start` 的返回码可能被脚本后续逻辑覆盖；前端会在完成后核对实际运行状态和路径。
- Scene第一版支持单场景播放、菜单栏停止与退出清理。Space切换动画仍可能短暂露出系统壁纸；多屏和五分钟稳定性尚未完成验收。本轮仅验证设置接线与离线／模拟边界，未逐场景验收交互和音频效果。暂不支持开机启动。
- 视频经 `WallpaperBackend` 协议控制；Scene由独立播放器接入统一协调，切换会先停止原引擎。
- 配置路径与现有控制脚本保持一致。更换素材位置前需要同步后端配置。
- 状态四秒刷新一次；首次预览生成逐个处理，避免同时解码多个 4K 视频。
- 状态读取失败时显示“状态未知”；轮播是否开启以任务注册为准，间隔/模式来自任务 plist。外部修改 plist 后未重新注册的情况尚需进一步校验运行时参数。
- 符号链接与素材目录外路径不可直接播放/删除。既有素材只扫描小写 `.mp4`，与控制脚本一致。
- XCTest 在本机 Command Line Tools 环境不可用，因此使用独立 Swift 断言程序验证核心边界。

## 进度入口


Scene实验进度：`WE场景-阶段2D离线视频帧验收.md`。核心位于 `Sources/WESceneCore`；
用 `bash scripts/check-scene.sh` 运行自检，`bash scripts/scene-probe.sh resources /path/scene.pkg` 生成只读 JSON 报告，
`bash scripts/scene-probe.sh still /path/scene.pkg /tmp/scene.png` 可尝试导出受限静态基础图及同名诊断 JSON。
没有可合成静态层时只写诊断、退出 3；静态图不能代替动态 scene 桌面播放。视频后端保持原有实现。
`bash scripts/scene-probe.sh frame /path/scene.pkg materials/name.tex 1 /tmp/scene-t1.png` 可离线查看指定视频纹理在 1 秒的基础合成帧；这同样不是连续播放或视觉等效验收。
