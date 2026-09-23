# Scene 阶段 2E：受限 colorkey 离线合成

日期：2026-09-24。状态：**离线预览迭代**，不提供连续 scene 播放、桌面挂载或可播放的 UI 后端。前置版本为 `255fe1f` / `scene-stage2d-preview.1`；本阶段提交与预览标签以 Git 日志为准。

## 实现范围

- 仅当图层上只有一个可识别的 `effects/colorkey/effect.json`，效果定义为版本 1、单 pass，材质指向 `effects/colorkey`，并且没有额外组合参数时，才对离线纹理采样应用抠色。禁用的效果按原图绘制；不支持的扩展参数或越界值让该图层跳过并留下诊断。
- 依据真实包内 `shaders/effects/colorkey.frag` 的可见公式：三个 RGB 通道绝对差求和，减容差后执行 `smoothstep(0.001, 0.002 + fuzziness, …)`，再以 `mix(alpha, 1, blend)` 乘原始像素 alpha。当前仅实现 `INVERT=0`、`FLATTEN=0` 的常规分支，不执行包内 shader。
- 仍为 CPU、逐像素、按时间点的近似合成。没有证明与 Wallpaper Engine 的颜色空间、采样过滤、效果链顺序或完整渲染一致。其他 shader/effects、脚本、粒子与运行时资源继续显式受限；`playable=false`、`faithful=false`。

## 验证

- `bash scripts/check-scene.sh`：121 项合成自测通过、0 失败。新增键色透明、非键色不透明、平滑边缘、原始 alpha 相乘、禁用效果、越界参数拒绝和不支持的组合拒绝。
- `swift build --disable-sandbox --target WESceneCore` 通过。默认 `swift build` 在当前工具沙箱里因嵌套 `sandbox-exec: sandbox_apply: Operation not permitted` 无法运行；关闭 SwiftPM 内层沙箱后可编译。
- `bash scripts/check.sh`：视频前端 34 项通过；未启动 UI 或修改桌面播放。
- 真实样本 `3483456356`：`materials/阿罗娜 人物.tex` 在 0 秒和 1 秒各导出 960×540 帧，实际时间为 0/1 秒。两帧 SHA-256 分别为 `23f5de339212934dcd59a733b0e0925a1bbdbabbd5d04d6e717c3f155d643a42` 与 `df39e5af732b6bc2c067b73c9b10380254b8e7908103b7ce235113a870942d98`；目视可见人物在樱花背景上，原先整片黄色背景已消失。输出仅在临时目录 `/private/tmp/wescene-stage2e.9NH1bN/`，不纳入 Git。
- 该样本仍有未实现的 `foliagesway`、`waterwaves`、`pulse` 和 workshop 效果，且部分图层因不支持的混合模式或缺失包内模型被跳过。不能把本次画面称为忠实还原，更不能称为桌面动态 scene 播放。
- 默认工具沙箱中的 AVFoundation 报 `Cannot Decode`；同一输入经获准的本机执行环境成功取帧。这是执行环境差异，未验证未来签名应用的解码权限。

## 下一阶段

优先设计连续帧调度与循环/暂停的**离线运行时原型**，先证明时间连续性与资源生命周期，再单独研究安全的桌面层挂载和 UI 能力判断。当前 `frame` 命令仍只能做离线取帧，不应接入“设为动态壁纸”。
