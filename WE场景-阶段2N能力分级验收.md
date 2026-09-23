# WE 场景阶段 2N：能力分级验收

日期：2026-09-24。只读检查原场景包；未启动应用、未改桌面或素材。

## 实现

新增 `WESceneInspection.capabilityReport(packageData:maxPreviewDimension:)` 和 CLI `capabilities`。先验证包内资源结构，再在最长边 1-960 像素的上限内实际尝试受限静态合成。报告分别列出 `resourceInspectionAvailable`、`restrictedStaticPreviewAvailable`、`desktopScenePlayable` 和 `faithfulSceneRendering`，并合并资源与预览诊断代码。预览失败保留错误及限制代码，不把资源可检查误报为预览可用。桌面播放和忠实渲染均保持 `false`。

资源报告原 `rendererUnavailable` 代码保留以兼容既有消费者，但文案改为准确描述：资源检查自身不渲染；已有受限预览并不具备完整效果链或桌面呈现。命令因不能提供桌面可播放能力，按约定输出 JSON 后退出 3。

## 验证

- 合成样本覆盖：资源齐全但预览失败、受限静态预览成功、越界尺寸拒绝；两种情况下均不允许桌面播放。
- `bash scripts/check-scene.sh`：145 项自测通过；`swift build --disable-sandbox --target WESceneCore` 通过；`bash scripts/check.sh`：34 项前端回归通过。
- 真实样本 `3483456356/scene.pkg` 的 `capabilities … 640`：包版本 `PKGV0022`，资源检查与受限静态预览均为 `true`，桌面播放与忠实渲染均为 `false`；输出限制包括 `effects`、`shader`、`script`、`projected3D`、`missingResource` 等，退出码 3 是预期降级，不是崩溃。

## 边界

静态预览仅是已有受限合成器的近似画面，不推断动态视频、完整效果或显示器输出。尚未将 scene 资源接到 UI 的图库或播放控制，也未形成桌面 scene 播放器。
