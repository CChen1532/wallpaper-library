# WE 场景阶段 2AB：Space 切换试验准备（预览）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 本阶段

独立 `WESceneDesktopProbe` 已监听 Space、显示器和睡眠通知，并在试验期间请求协作停止。本阶段在本地诊断 JSON 中增加机器可读的 `stopCause`，区分 `activeSpaceChanged`、`displayChanged`、`systemSleep`、`screensSleep`、用户停止、控制窗口关闭与应用退出。既有 `stopRequest` 仍保留供人阅读。新字段为可选，旧摘要仍可解码；诊断中不写场景包路径或像素。

Space 通知触发时只停止当前隔离试验，不自动重建显示面或切换系统壁纸。试验仍由控制窗口手动选包、选屏、勾选当次许可并点击开始；最多5秒、10Hz、50帧。正式UI与phonto控制路径未更改，`desktopScenePlayable=false`、`faithfulSceneRendering=false`保持不变。

## 验证

`bash scripts/check-desktop-probe.sh` 通过；其中临时目录自检证明 `activeSpaceChanged` 会保留到 `stopped` 终态，且未创建窗口。`bash scripts/check-scene.sh` 161项通过，`bash scripts/check.sh` 39项通过；`bash scripts/build-desktop-probe.sh` 完成Release构建与本地签名。以上均未启动真实桌面试验，也不能证明Space切换后的窗口层级、图标可用或清理效果。

## 真实验收待办

需新的当次许可，并由用户在短时试验里实际切换Space、目视确认目标桌面画面与图标。试验前后读取phonto状态，试验后检查应用已退出及 `last-trial.json` 的 `stopCause=activeSpaceChanged`、终态和帧数。如果5秒内未触发切换，记录为未验收，不从普通窗口或离屏自检推断通过。外接屏、睡眠和phonto共存另行逐项验收。

## 2026-09-24 当次 Space 试验

用户明确允许一次5秒隔离桌面试验。通过图形控制窗口选择既有真实包、人物视频纹理及内置屏幕1，勾选当次许可后开始。新的本地摘要（运行ID `2AC4F894-229C-4F2F-8685-0FDB7181470A`）记录 `surfaceWindowNumber=16715`、`deliveredFrames=2`、`distinctFrames=2`、`stage=stopped`、`failureCategory=CancellationError`、`stopCause=activeSpaceChanged`，开始与完成时间相隔约1秒。应用清单显示探针已退出；`phonto-wall status` 前后均为未运行、轮播未开启。

图形工具在画面变化时返回屏幕采集错误，不能从采集结果推断桌面或图标正常。用户反馈“在一瞬间闪了一下，随后关闭”，并明确表示自己**没有切换Space**。因此这是探针自身建面/激活附近的Space通知导致的误停，不是用户切换验收。Space视觉行为标记为未验收。

## 误停修正

显示面打开时，Space通知可能由窗口建立本身触发。探针现在从建面前起暂缓1秒处理 `activeSpaceDidChangeNotification`；1秒后收到的通知仍立即协作停止。其他显示器、睡眠、用户停止和退出通知不受此门控影响。这个短暂窗口内的真实Space切换不会被该通知停止，但整体仍受5秒上限约束；正式功能不使用此策略。下一次试验请在画面稳定约1秒后再切换Space。

`TrialSpaceGate` 以可注入时间自检了未建面、暂缓窗口及边界时刻。修正后 `check-desktop-probe.sh`、Release构建与签名验证、`git diff --check` 通过；未再次启动真实桌面显示面。要复验仍需新的当次许可。

## 2026-09-24 第二次当次试验

用户另行允许一次5秒复验。新的本地摘要（运行ID `255C2B52-9E44-4B3B-86BA-8489EA7C51CD`）记录 `stage=completed`、`deliveryStopReason=durationLimit`、31次交付且31种画面、耗时5.018秒、窗口号17945；没有 `stopCause`，即探针没有记录到Space切换通知。应用清单显示探针已退出，phonto仍未运行且轮播关闭。启动即误停没有复现。用户明确表示切换了Space，并反馈图标被遮挡或无法点击；因此本次Space行为**未通过**，不能把正常满时退出当作通过。

## 跨Space遮挡修正预览

原显示面使用 `.canJoinAllSpaces`，会把候选桌面窗口带到其他Space；这与用户的图标异常反馈相符，但仅凭反馈无法证明唯一根因。现将该选项移除，仅保留 `.stationary` 和 `.ignoresCycle`，目标是让试验显示面留在创建它的Space。增加 `ignoredStartupSpaceNotifications` 计数，用于下次辨认切换通知是否落在1秒启动门控内。五秒/帧数/像素上限、一次性许可和正式能力关闭均不变。

修正当时的无窗口自检、Release构建、签名验证和差异检查通过；当时尚未实机复验。复验结果见下节。

## 2026-09-24 最后一次当次复验

用户再次明确允许一次5秒试验。新的本地摘要（运行ID `22B73B2C-4682-41B5-B98E-7956AF7CF308`）记录 `stage=completed`、`deliveryStopReason=durationLimit`、31次交付且31种画面、耗时5.004秒、窗口号18663；`ignoredStartupSpaceNotifications` 与 `stopCause` 均未出现。应用清单显示探针已退出；phonto仍未运行、轮播关闭。用户确认切换到另一个Space后图标正常且可用，5秒结束后无残留。此目视结果支持移除跨Space显示后的单屏短时行为通过。

**范围与未解问题：** 探针没有记录到Space切换通知，因此不能声称“切换通知会立即停止交付”通过；本次靠固定5秒上限清理。无法从诊断解释通知未出现的原因，也不能推断所有Space、全屏应用、外接显示器或睡眠行为。`desktopScenePlayable=false`、`faithfulSceneRendering=false`保持不变，正式应用没有Scene播放入口。下一阶段可单独调查通知/切换身份，再做外接屏等分项验收。

## 后续证据更正（阶段2AC）

用户随后说明，2AB时所谓“切换Space”采用的是四指**向上**滑动。该手势打开Mission Control，本身不证明已经点选另一个桌面。因此上节“切换到另一个Space后图标正常”的表述只能保留为当时的用户目视反馈，不能算跨Space验收。已证实的事实是：独立探针在所选桌面显示了31种画面、5秒后退出，用户看到图标正常且无残留；实际桌面1→桌面2切换及通知驱动即时停止仍未验收。详见 `WE场景-阶段2AC-Space通知诊断预览.md`。
