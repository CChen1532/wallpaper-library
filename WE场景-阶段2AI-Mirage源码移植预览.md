# 阶段 2AI：Mirage Scene 源码移植预览

## 范围与版本

用户要求将 MirageWallpaper 的 Scene 实现直接用于本项目。`ThirdParty/MirageWallpaper` 是上游源码的 Git 子模块，固定在 v1.1.4、提交 `d639939b925f08cfa0e5227ed9bea79529348fd6`。本阶段保留 SceneRenderer 的 C++／Vulkan／MoltenVK 渲染链，Swift 侧只控制独立 `SceneWallpaper` 子进程，不改写已有 phonto 视频后端。Mirage 的 LICENSE 与上游第三方授权文件随子模块保留；发布包含该组件的产品前，需要核对 GPLv3 及各依赖的分发义务。

本机只有 Command Line Tools，缺少完整 Xcode、Homebrew、CMake、Ninja 和上游要求的 LLVM／Vulkan 依赖，**未在本机从源码编译 Mirage SceneRenderer**。为验证桥接接口，使用同一 v1.1.4 官方 arm64 发布包作为开发运行时。ZIP 的 SHA-256 固定为 `491117e579a92fb69749dc6d4068aa6589a599e7fc041ae6943e0dc456ea07cb`；脚本验证摘要、签名和 `--help` 控制接口后解压到被 Git 忽略的 `dist/MirageSceneRuntime.app`。运行包不会进入提交。具备上游构建依赖的机器可在子模块中执行 `./scripts/build_all.sh scene` 从固定源码编译。

## 当前实现

- `MirageSceneBridge` 检查运行包的渲染器、assets、MoltenVK ICD 与 Frameworks；只接受常规 `scene.pkg` 和非零显示器 ID。试验参数限制 30 fps、静音、无频谱、单显示器，使用 `--deferred-show` 等到场景及首帧准备完成后才发送激活命令。
- `MirageSceneChild` 只管理其自身启动的进程；解析行分隔 JSON 生命周期事件，通过标准输入发送 `activate`／`deactivate`／`quit`，在异常或超时时回收子进程。上游 `--run-seconds 90` 是独立的最终停止上限，实际显屏试验在激活 5 秒后停止。
- `MirageSceneBridgeProbe --selftest` 使用假渲染器验证事件、命令、失败识别和清理；`--verify-runtime` 只执行官方渲染器的 `--help`，不创建桌面窗口；`--trial` 是显式许可后才使用的开发入口，启动前只通过 `phonto-wall status` 确认既有视频壁纸已停且轮播关闭。
- 正式 UI 仍使用既有 WallpaperBackend；Mirage Scene 尚未加入“设为动态壁纸”。`desktopScenePlayable=false`、`faithfulSceneRendering=false` 不变。

## 可重复命令

```sh
git submodule update --init ThirdParty/MirageWallpaper
bash scripts/prepare-mirage-scene-runtime.sh /path/to/Mirage-v1.1.4-arm64.zip
swift build --disable-sandbox -c release --product MirageSceneBridgeProbe
.build/release/MirageSceneBridgeProbe --selftest
.build/release/MirageSceneBridgeProbe --verify-runtime dist/MirageSceneRuntime.app
```

以下命令**会覆盖指定显示器桌面**，只能在项目要求的当次许可、当前显示器 ID 核实和 phonto 停止核实后运行：

```sh
.build/release/MirageSceneBridgeProbe --trial dist/MirageSceneRuntime.app /path/to/scene.pkg DISPLAY_ID --consent
```

## 验证边界与后续

本阶段已通过桥接器 Release 构建、假渲染器生命周期自检、官方包 SHA-256／签名／CLI 契约校验、164 项原 Scene 自检、39 项正式前端回归和整包 Release 构建。上述结果只证明桥接与离屏控制准备，不能证明 Mirage 在本机的场景画质、实显帧率、图标点击、Space、五分钟稳定性或与运行中的 phonto 共存。获得新的当次许可后先做外接屏 5 秒短时目视与退出检查；再决定是否值得替换正式 Scene 后端以及如何进行长时验收。不得用短时预览替代正式能力门槛。
