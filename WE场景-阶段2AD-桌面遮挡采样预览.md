# WE 场景阶段 2AD：桌面显示面遮挡采样（预览）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 本阶段边界

2AC在用户明确点选“桌面2”再返回时，独立GUI监听仍未收到 `NSWorkspace.activeSpaceDidChangeNotification`。本阶段改为观察桌面试验窗口的 `NSWindow.occlusionState`：每次串行交付帧后只读取一次状态，统计可见样本、完全遮挡样本，以及可见→完全遮挡的次数，写入既有不含路径的 `last-trial.json`。成功或失败时都记录现有计数。不使用这些尚未实测的值自动停止；原5秒/10Hz/50帧/640像素边界、单Space窗口和资源清理保持不变。

[Apple文档](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property)把 `.visible` 定义为窗口至少部分可见，未设置表示完全遮挡；它没有承诺此状态必能识别桌面级窗口的Space切换。因此本阶段先取样，不将它写成可靠的切换检测。正式应用仍没有Scene播放入口，`desktopScenePlayable=false`、`faithfulSceneRendering=false`。

## 验证与实机门槛

`TrialOcclusionSamples` 的离屏自检覆盖可见、不可见及可见→不可见转换；诊断JSON写入自检通过。`bash scripts/check-desktop-probe.sh`、`bash scripts/check-scene.sh`（161项）、`bash scripts/check.sh`（39项）、Release构建及签名验证通过。上述测试没有启动桌面显示面；实机取样需新的当次许可。

实机时只选既有约65.3 MB真实包、人物视频纹理和内置屏幕1；开始前phonto未运行、轮播关闭。用户须在画面出现后从Mission Control顶部实际点“桌面2”，而不只打开Mission Control。结束后比对诊断样本、应用退出、phonto状态和用户目视图标/残留；无论样本怎样，单次5秒测试不能证明跨Space长期稳定或完整效果链。

## 2026-09-24 当次实机结果

用户明确允许本次独立5秒桌面试验。所选真实包和纹理同既有单屏样本，内置屏幕1。新的本地摘要（运行ID `DF6719CA-2506-432F-8D6D-FAAF40F7C1E2`）记录：显示面窗口号23359、交付21帧且21种画面、启动期忽略1次Space通知，随后 `stopCause=activeSpaceChanged`、`stage=stopped`、`failureCategory=CancellationError`。遮挡采样为可见21次、完全遮挡0次、可见→遮挡转换0次。应用清单显示探针已退出，phonto前后均未运行且轮播关闭。用户确认在Mission Control顶部点了“桌面2”，切换后图标正常、结束后无残留。

这次证据支持**单显示器、一次短时真实Space切换由通知触发协作清理**。遮挡采样只覆盖停止前的已交付帧；不能从0次遮挡推断切换后窗口仍可见，也不能声称遮挡状态能作为通知缺席时的回退。2AC的0通知观察仍保留为当时事实，但本次证明正确的实际切换至少在所测配置下能够产生通知。外接屏、睡眠、运行中的phonto共存、长时稳定性与完整效果链仍未验收；`desktopScenePlayable=false`、`faithfulSceneRendering=false`不变。
