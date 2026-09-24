# WE 场景阶段 2Z：隔离桌面试验实现（桌面画面待目视确认）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 已实现的预览能力

新增独立可执行目标 `WESceneDesktopProbe`，**不接入正式「视频壁纸」应用或 phonto 控制入口**。为了让界面工具能安全启动控制窗口，普通启动现在只展示控制窗口、不会自动创建桌面显示面；需人手动选择单个 `scene.pkg`、包内视频 TEX 路径和一个显示器，勾选当次许可确认，再点击「开始 5 秒桌面试验」才尝试创建隔离窗口。`--desktop-trial` 也不跳过该确认。构建与自检不会触碰真实桌面；非法参数直接退出。

试验显示面使用所选 `NSScreen` 的显示 ID 与完整屏幕矩形快照；建面前重新比对，屏幕布局一旦变化便停止。窗口候选层级为 Core Graphics 的 desktop-window level，非交互、无阴影，尝试跨 Space 且不加入窗口循环。**这些 API 选择只确定试验候选实现；未经实际桌面目视，不能断定系统壁纸前后层次、图标可用或全屏行为。**系统壁纸设置和 phonto 进程/任务均不被本目标写入或控制。

帧仍经阶段 2W 的串行交付器：5 秒、10 Hz、最多 50 帧、最长边 640 像素；包须为不超过 64 MiB 的非链接常规文件。帧交付器在正常、错误及取消路径关闭解码源和显示接收端；显示接收端移除窗口。控制窗口关闭、退出请求、显示器参数变化、Space 切换、系统或屏幕睡眠均请求协作停止。单次解码/合成调用仍不能立即抢占，限额在调用边界检查；因此绝不将「5 秒」解释为强制进程墙钟上限。

API 依据：[Apple 的窗口层级说明](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct)、[桌面层级键](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey/desktopwindow)、[Space/窗口集合行为](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)、[屏幕 ID 与矩形](https://developer.apple.com/documentation/appkit/nsscreen/devicedescription)。这些文档不保证第三方桌面试验在当前 macOS 配置中实际可见，需单独验收。

## 本轮验证

| 验证 | 结果和边界 |
|---|---|
| `bash scripts/check-desktop-probe.sh` | Debug 构建通过；显示 ID/几何变化、非法几何、一次性停止和 RGBA 颜色/方向/透明度/边界自检通过；非法参数入口退出 2。自检/非法参数路径都不创建窗口。 |
| `bash scripts/build-desktop-probe.sh`、`swift build --disable-sandbox`、`codesign --verify --deep --strict`、`plutil -lint` | Release 独立应用、全包构建、签名及 Info.plist 结构通过；**未启动** `--desktop-trial`。 |
| `bash scripts/check-scene.sh`、`bash scripts/check.sh` | 161 项 Scene 与 39 项正式视频前端回归通过；不包含真实桌面层级和生命周期视觉验收。 |
| `git diff --check` | 通过。 |

DeepSeek 提供的抽象生命周期清单仅用作交叉检查；资源归属按本地 `WESceneFrameDelivery` 实现修正为交付器统一关闭源与接收端，避免协调器重复关闭。其「正式桌面能力为 false 就拒绝试验」建议没有照搬：本目标是隔离开发试验，正式能力仍为 false。

## 2026-09-24 单显示器实机尝试

经用户当次明确许可，先用 `phonto-wall status` 只读检查：phonto 未运行，轮播未开启。独立签名应用通过系统界面启动；控制窗口正常显示内置屏幕 `Built-in Retina Display · 1`，手选真实 `3483456356/scene.pkg`、填入 `materials/阿罗娜 人物.tex`，勾选确认并点击开始。控制窗口进入只读加载/短时交付状态；随后应用清单显示实验进程 `isRunning=false`。试验后再次只读检查，phonto 仍未运行、轮播仍未开启。未控制或切换原视频壁纸。

目前界面截图工具只能捕获控制窗口或 Finder 窗口，无法捕获桌面背景层；应用清单只有退出状态，没有成功/错误退出码。用户后续表示“不确定或没来得及观察”，因此尚不能确认 Scene 画面真的显示在桌面、人物持续运动或图标仍可用；也没有测试 phonto **正在播放时**的共存。阶段2AA新增的诊断记录只对未来运行生效，不能回溯本次结果。

## 尚未通过的门槛与下一步

本轮已在用户许可下尝试一次单显示器短时桌面试验，但没有证据证明候选窗口位于图标之后、画面持续运动、在所有 Space 中正确显示、睡眠/热插拔后清理，或与正在运行的 phonto 视频桌面输出共存。没有修改系统壁纸设置。`desktopScenePlayable=false`、`faithfulSceneRendering=false` 保持不变；不能把此预览目标称作可用 Wallpaper Engine 桌面播放后端。

用户目视结果不确定；阶段2AA已增补不影响桌面的最小诊断，仍须取得新的当次许可才能复验。复验时读取摘要并请用户目视画面与图标；若可见，也只推进 Space、外接屏、睡眠和 phonto 共存的分项试验。不能靠一次普通窗口截图、进程退出或诊断帧数替代桌面画面验收。
