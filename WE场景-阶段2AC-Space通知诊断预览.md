# WE 场景阶段 2AC：Space 通知诊断（预览）

日期：2026-09-24（Asia/Kuala_Lumpur）

## 目标与实现

阶段2AB在桌面短时试验中没有记录到用户所称的Space切换通知。先核对操作定义：用户随后说明当时用“四指向上划”；这仅打开Mission Control，不能证明点选了另一桌面。因此更正2AB的跨Space目视结论，保留其单屏5秒画面、图标与自动清理观察。

在独立 `WESceneDesktopProbe` 控制窗口增加“监听 Space 通知 20 秒”按钮。按钮不要求选包、视频纹理、显示器或桌面试验许可，且不调用显示面或帧交付器；它只在已有的 `NSWorkspace.shared.notificationCenter` 观察者上计数并显示结果。监听期间禁用桌面试验启动，20秒后恢复。该诊断没有触碰系统壁纸、phonto或真实素材。正式应用的Scene播放能力保持关闭。

Apple的 [`activeSpaceDidChangeNotification` 文档](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)说明应在 `NSWorkspace` 的通知中心注册，通知对象是共享 `NSWorkspace`，没有Space ID等 `userInfo`。现有观察者已使用该中心；通知次数不能证明起止Space身份。Apple的[窗口集合行为文档](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)说明 `.canJoinAllSpaces` 允许窗口出现在所有Space，故2AB已将其从隔离显示面移除。

## 验证结果

- 首次命令行监听还注册了应用激活通知，出现Launch Services注册错误，0条Space通知；该次不可用于判断系统行为。去掉无关监听后，在正常macOS会话运行的15秒命令行诊断无注册错误，但用户报告切换Space时仍为0条。后续尝试AppKit事件循环的命令行入口没有按时退出，已中断该诊断进程；它不用于结论。这些临时命令行入口最终未保留在源码中。
- 独立GUI控制窗口的20秒监听按时结束，状态显示0条通知；用户明确表示期间在Mission Control顶部点了“桌面2”并返回“桌面1”。这是本阶段最直接的证据。仅凭用户操作和0计数，尚不能定位是系统通知未发、进程未收到，还是观察/时间对齐方面的其他问题。
- `bash scripts/check-desktop-probe.sh`、`bash scripts/check-scene.sh`（161项）、`bash scripts/check.sh`（39项）、Release构建、签名验证及`git diff --check`通过；GUI监听按钮在实机可见、20秒后恢复可用。没有启动Scene桌面显示面。

## 结论与下一步

不能把 `activeSpaceDidChangeNotification` 当作本机隔离试验的唯一即时停止保障；固定5秒上限、单Space显示面、协作清理仍保留。尚未证明真正跨Space时桌面画面和图标的行为，也未证明窗口可见性/遮挡状态可作为替代信号。下一阶段先以公开的窗口可见性或生命周期信号设计可观测的回退，再在取得新的当次许可后做真实桌面1→桌面2短时目视验收。`desktopScenePlayable=false`、`faithfulSceneRendering=false`继续保持。
