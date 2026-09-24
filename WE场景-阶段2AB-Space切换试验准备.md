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
