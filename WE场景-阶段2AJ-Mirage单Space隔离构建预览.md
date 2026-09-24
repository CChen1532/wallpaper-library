# WE 场景阶段 2AJ：Mirage 单 Space 隔离构建（预览）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 发现与决策

在准备源码版 Mirage 的长时桌面试验时，固定 v1.1.4 源码的 `MacDesktopHost.mm` 将桌面窗口配置为 `NSWindowCollectionBehaviorCanJoinAllSpaces | Stationary | IgnoresCycle`，窗口层位为图标层减 1。此前 2AI 的约 5 秒外接屏目视反馈只覆盖当次画面、画质和图标，**没有检验跨 Space 行为**。用户已把所有 Space 支持排在长时稳定播放之后，因此不能直接将这个原始构建扩为五分钟试验。

本阶段建立项目自有的最小补丁 `patches/mirage-single-space.patch`，只从窗口行为中移除 `CanJoinAllSpaces`，保留层位、`Stationary`、`IgnoresCycle`、鼠标忽略、延迟显示与其他渲染逻辑。`scripts/build-mirage-single-space-source.sh` 从固定 v1.1.4 在被 Git 忽略的 `dist/MirageSingleSpaceSource` 建立隔离副本并应用补丁；复用原固定源码构建出的 FFmpeg 库，不改动 `ThirdParty/MirageWallpaper`。脚本复核提交 ID、补丁可反向匹配、仅目标文件有跟踪改动，拒绝符号链接源目录。

`scripts/prepare-mirage-source-runtime.sh --single-space` 将隔离产物准备到另一个本机专用且被 Git 忽略的 `dist/MirageSingleSpaceRuntime`，继续检查 Vulkan Loader、MoltenVK、assets 与渲染器，并拒绝覆盖已有目录或符号链接。源文件比渲染器更新时拒绝打包，避免明显陈旧的二进制。此目录仍依赖本机 Homebrew、FFmpeg 等绝对路径，**不可直接分发**。

## 离屏验证

- 原始固定子模块提交仍为 `d639939b925f08cfa0e5227ed9bea79529348fd6`，工作区保持干净；项目补丁在原始源码上 `git apply --check` 通过，隔离副本仅 `MacDesktopHost.mm` 有预期差异且 `git diff --check` 通过。
- 隔离副本从头完成 arm64 Release 构建，产出 `SceneWallpaper`、`SceneViewer` 和 `libMirageSceneSaver.dylib`；`build-mirage-single-space-source.sh --check` 及新渲染器 `--help` 通过。
- `MirageSceneBridgeProbe --verify-runtime dist/MirageSingleSpaceRuntime` 通过，仅检查文件和 CLI 契约；没有加载真实场景、建立窗口或更改桌面。脚本语法与主项目差异检查通过。

## 验收边界与下一步

源码明确去掉了跨 Space 加入标志，**但目前没有真实桌面验收证明它只留在目标 Space**，也没有证明图标安全、画质、退出后无残留或五分钟稳定性。下一阶段须取得新的当次许可，先用已构建的隔离单 Space 变体做约 5 秒实机试验并观察实际切换；通过后再给独立探针增加有界五分钟模式与独立停止上限，另行授权进行长时验收。正式 `desktopScenePlayable=false`、`faithfulSceneRendering=false` 不变；所有 Space 适配仍排在长时稳定验收之后。
