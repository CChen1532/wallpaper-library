# WE 场景阶段 2Z：隔离桌面试验实现（待真实桌面验收）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 已实现的预览能力

新增独立可执行目标 `WESceneDesktopProbe`，**不接入正式「视频壁纸」应用或 phonto 控制入口**。普通启动立即退出；只有显式 `--desktop-trial` 才展示控制窗口，再由人手动选择单个 `scene.pkg`、包内视频 TEX 路径和一个显示器，并点击「开始 5 秒桌面试验」后，才尝试创建桌面层级的隔离窗口。构建与自检不会触碰真实桌面。

试验显示面使用所选 `NSScreen` 的显示 ID 与完整屏幕矩形快照；建面前重新比对，屏幕布局一旦变化便停止。窗口候选层级为 Core Graphics 的 desktop-window level，非交互、无阴影，尝试跨 Space 且不加入窗口循环。**这些 API 选择只确定试验候选实现；未经实际桌面目视，不能断定系统壁纸前后层次、图标可用或全屏行为。**系统壁纸设置和 phonto 进程/任务均不被本目标写入或控制。

帧仍经阶段 2W 的串行交付器：5 秒、10 Hz、最多 50 帧、最长边 640 像素；包须为不超过 64 MiB 的非链接常规文件。帧交付器在正常、错误及取消路径关闭解码源和显示接收端；显示接收端移除窗口。控制窗口关闭、退出请求、显示器参数变化、Space 切换、系统或屏幕睡眠均请求协作停止。单次解码/合成调用仍不能立即抢占，限额在调用边界检查；因此绝不将「5 秒」解释为强制进程墙钟上限。

API 依据：[Apple 的窗口层级说明](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct)、[桌面层级键](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey/desktopwindow)、[Space/窗口集合行为](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)、[屏幕 ID 与矩形](https://developer.apple.com/documentation/appkit/nsscreen/devicedescription)。这些文档不保证第三方桌面试验在当前 macOS 配置中实际可见，需单独验收。

## 本轮验证

| 验证 | 结果和边界 |
|---|---|
| `bash scripts/check-desktop-probe.sh` | Debug 构建通过；显示 ID/几何变化、非法几何、一次性停止和 RGBA 颜色/方向/透明度/边界自检通过；无参数入口退出 2 并提示默认禁用。两条路径都不创建窗口。 |
| `bash scripts/build-desktop-probe.sh`、`swift build --disable-sandbox`、`codesign --verify --deep --strict`、`plutil -lint` | Release 独立应用、全包构建、签名及 Info.plist 结构通过；**未启动** `--desktop-trial`。 |
| `bash scripts/check-scene.sh`、`bash scripts/check.sh` | 161 项 Scene 与 39 项正式视频前端回归通过；不包含真实桌面层级和生命周期视觉验收。 |
| `git diff --check` | 通过。 |

DeepSeek 提供的抽象生命周期清单仅用作交叉检查；资源归属按本地 `WESceneFrameDelivery` 实现修正为交付器统一关闭源与接收端，避免协调器重复关闭。其「正式桌面能力为 false 就拒绝试验」建议没有照搬：本目标是隔离开发试验，正式能力仍为 false。

## 尚未通过的门槛与下一步

本轮**没有启动或修改真实桌面壁纸**，没有证据证明候选桌面窗口位于图标之后、在所有 Space 中正确显示、睡眠/热插拔后清理，或与当前 phonto 视频桌面输出共存。`desktopScenePlayable=false`、`faithfulSceneRendering=false` 保持不变；不能把此预览目标称作可用 Wallpaper Engine 桌面播放后端。

下一步先取得用户当次明确许可，再记录现有 phonto 状态，仅临时运行签名独立应用进行单显示器短时目视试验；任何异常立即用控制窗口停止，复核进程退出及原视频壁纸状态。之后再分别验证 Space、外接屏变化、睡眠和错误路径，不能靠一次普通窗口截图替代。
