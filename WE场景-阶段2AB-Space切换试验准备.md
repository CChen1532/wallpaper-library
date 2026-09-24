# WE 场景阶段 2AB：Space 切换试验准备（预览）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 本阶段

独立 `WESceneDesktopProbe` 已监听 Space、显示器和睡眠通知，并在试验期间请求协作停止。本阶段在本地诊断 JSON 中增加机器可读的 `stopCause`，区分 `activeSpaceChanged`、`displayChanged`、`systemSleep`、`screensSleep`、用户停止、控制窗口关闭与应用退出。既有 `stopRequest` 仍保留供人阅读。新字段为可选，旧摘要仍可解码；诊断中不写场景包路径或像素。

Space 通知触发时只停止当前隔离试验，不自动重建显示面或切换系统壁纸。试验仍由控制窗口手动选包、选屏、勾选当次许可并点击开始；最多5秒、10Hz、50帧。正式UI与phonto控制路径未更改，`desktopScenePlayable=false`、`faithfulSceneRendering=false`保持不变。

## 验证

`bash scripts/check-desktop-probe.sh` 通过；其中临时目录自检证明 `activeSpaceChanged` 会保留到 `stopped` 终态，且未创建窗口。`bash scripts/check-scene.sh` 161项通过，`bash scripts/check.sh` 39项通过；`bash scripts/build-desktop-probe.sh` 完成Release构建与本地签名。以上均未启动真实桌面试验，也不能证明Space切换后的窗口层级、图标可用或清理效果。

## 真实验收待办

需新的当次许可，并由用户在短时试验里实际切换Space、目视确认目标桌面画面与图标。试验前后读取phonto状态，试验后检查应用已退出及 `last-trial.json` 的 `stopCause=activeSpaceChanged`、终态和帧数。如果5秒内未触发切换，记录为未验收，不从普通窗口或离屏自检推断通过。外接屏、睡眠和phonto共存另行逐项验收。
