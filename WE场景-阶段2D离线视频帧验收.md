# Scene 阶段 2D：视频纹理离线逐帧合成

日期：2026-09-23。状态：已验证的 **离线取帧** 预览迭代；没有连续播放、桌面窗口或 UI scene 后端。前置版本：`22fe356` / `scene-stage2c-preview.1`；本阶段提交和标签以 Git 日志为准。

## 本阶段实现

- `WESceneInspection.videoTextureFrame(packageData:texturePath:atSeconds:)` 从包内指定 TEX 的单图单载荷提取 MP4，检查 `ftyp` box 在载荷边界内、路径安全、尺寸/内存预算、单视频轨、TEX 与轨道尺寸相符、时长与请求时间有效。通过系统 AVFoundation 按时间解码，返回请求/实际时间、时长和 RGBA 帧。
- `WESceneInspection.offlineFrame(packageData:videoTexturePath:atSeconds:maxDimension:)` 将该帧只替换同路径图层的纹理，并复用 2C 基础合成；未被可合成图层引用时拒绝。`frameMode=offlineVideoTextureFrame`、`playable=false`、`faithful=false`，其余视频纹理和未实现效果仍按原有限制跳过。
- CLI `frame <scene.pkg> <materials/name.tex> <seconds> <out.png> [max-edge]` 写 PNG 与同名诊断 JSON；`video-payload <file.tex> <out.mp4>` 仅供检查包内载荷且拒绝覆盖。没有任何命令控制桌面壁纸。解码临时目录自动清理；AVFoundation 禁止媒体引用到 MP4 文件之外。
- 不对时间越界做钳制或循环；不执行脚本，也不把离线两帧的差异冒充为连续播放验收。效果器诊断现在指出声明的效果路径，帮助定位视觉差异。

## 验证与证据

- `bash scripts/check-scene.sh`：113 项合成自测通过、0 失败，新增载荷切片/box 越界、指定路径帧替换、未引用帧拒绝和不可播放标记。`swift build --target WESceneCore` 通过；现有视频前端 `bash scripts/check.sh` 34 项通过。
- 真实样本 `3415680813`：`materials/RecorderClip_001.tex` 的 MP4 为 H.264、3840×2160、约 23.93 秒；0 秒与 1 秒实际取帧时间分别为 0/1 秒，960×540 合成 PNG 的 SHA-256 不同且目视可见动画变化。报告的 `playable=false`、`faithful=false`。结果在本任务 `outputs/scene-stage2d/3415680813-t{0,1}.{png,json}`，不纳入 Git。
- 真实样本 `3483456356`：`materials/阿罗娜 人物.tex` 在 0/1 秒均成功取帧并与静态樱花层合成，图像摘要不同；但人物视频的黄色背景需要 `effects/colorkey/effect.json` 抠色，目前尚未实现，因此画面明显不忠实。诊断明确列出该效果。结果在 `outputs/scene-stage2d/3483456356-t{0,1}.{png,json}`，不纳入 Git。
- 对 `3415680813` 负时间、24 秒越界和 `../` 纹理路径，CLI 均明确退出 1，未输出 PNG。默认工具沙箱里的 AVFoundation 报 `Cannot Decode`，同一真实输入在获准的本机执行环境中成功；这只证明当前执行环境权限差异，不代表未来签名应用已具备相同解码权限。
- 曾为核对格式临时提取一个约 92 MiB MP4，并用 `ffprobe` 确认 H.264/时长后删除；原 scene.pkg 与 TEX 均未更改。DeepSeek 只收到无敏感内容的阶段摘要，提出测试边界清单；主代理按真实样本和代码逐项复核，未直接采纳其未验证结论。

## 复现

```sh
bash scripts/check-scene.sh
swift build --target WESceneCore
bash scripts/scene-probe.sh frame /absolute/path/scene.pkg materials/RecorderClip_001.tex 0 /tmp/scene-t0.png 960
bash scripts/scene-probe.sh frame /absolute/path/scene.pkg materials/RecorderClip_001.tex 1 /tmp/scene-t1.png 960
```

`frame` 需要系统视频解码能力；所选材质路径必须来自该包的资源报告。输出只用于离线检查，**不能直接作为“设为动态壁纸”能力开放**。Apple 的 [按时间生成图像 API](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image%28at%3A%29)会返回实际帧时间；[媒体引用限制](https://developer.apple.com/documentation/avfoundation/avassetreferencerestrictions/forbidall)确保解码器只引用容器内数据。

## 下一阶段

优先研究并实现受限 `colorkey` 效果语义，再设计连续帧调度、循环/暂停、资源生命周期与桌面层挂载；分别验证视觉等效和桌面实际运动。仍需考虑脚本、粒子、其它 shader/effects、运行时资源以及 macOS 签名/权限。只支持两个离线时间点的场景不得标记为可播放。
