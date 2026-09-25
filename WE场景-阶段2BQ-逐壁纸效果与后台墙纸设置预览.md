# 阶段 2BQ：逐壁纸场景效果与后台墙纸设置（0.2.14 预览）

2026-09-25。用户要求在场景详情右栏直接修改作者水印及场景支持的效果，并解决每次切换时系统设置抢到前台。

右栏现在读取所选场景的 `project.json/general.properties`，展示通过校验的布尔、滑块、枚举、颜色及文字输入。优先使用作者声明的排序；水印始终放在顶部并默认关闭，用户可以只为这张壁纸重新开启。HTML 链接、远程图片、纯文字说明、组标题和快捷键元数据不被执行，也不当作可编辑控件。各选项按规范 `scene.pkg` 路径独立存入应用偏好；运行前重新按该场景当前声明校验，只把与作者原默认值不同的设置写入独立 JSON 并交给 Mirage 的 `--user-properties`。动态层和从该实例截取的过渡静帧使用同一组值，原 `scene.pkg` 与 `project.json` 不被改写。正在播放时修改先保存；“应用到此壁纸”通过现有单引擎协调流程重启当前场景。

抢前台的直接原因是原代码对每次自动底图调用 `NSWorkspace.shared.open(pane)`。现有墙纸页已经能定位“在所有空间中显示”开关时不重复打开；需要切到墙纸页时使用 `NSWorkspace.OpenConfiguration.activates = false`。这是 [Apple 对该属性的公开定义](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/activates)；[GitHub 的 macOS 系统设置 URL 收录](https://github.com/jaywcjlove/SystemSettings-URLs-macOS)验证了墙纸面板 URL，[后台打开实践](https://github.com/Hacker-Valley-Media/Interceptor/blob/main/.agents/skills/interceptor-macos/references/background-first.md)也提示已运行应用应尽量跳过重复打开。以上网页只读参考，没有执行其中的命令或指令。

验证：82项 Scene 集成检查、39项后端检查、Debug 与 Release 构建、运行时与9项输入策略检查、完整包深度签名通过。真实 `1000000006` 场景的详情右栏出现14个可编辑效果，作者水印显示关闭；在 UI 中临时开启它、切到另一场景、再切回仍保持本场景开启，随后已恢复为关闭。当前版成功进入目标场景桌面播放；用户目视确认首次启动时壁纸应用仍在前台。此后实机从若叶睦切到测试场景B，再切回，均显示“场景正在桌面播放”；用户目视确认两次均没有跳出系统设置。两次自动底图账本均为 `applied`，庭院和若叶睦底图 PNG 的 SHA-256 分别为 `b404a0ad241825663accd1141d426d26512e9dd278b9404acddf4c49935f1c95`、`cdb36ba4e0b1a1011741df653113b395bae9eb1e88868a584ed965b53256ddbc`。此外，在若叶睦播放中关闭“雾”并点击“应用到此壁纸”，覆盖文件变为 `{"fog":false,"watermark":false}`，场景重新进入桌面播放；随后恢复“雾”并重新应用，覆盖文件回到 `{"watermark":false}`。这次验证没有替代 Space 动画的视觉验收。

本轮签名后系统辅助功能列表曾再次绑定到历史同标识 `.app` 包，导致首次播放因缺权限回滚。25个历史备份保留全部字节，只把扩展名可逆改为 `.app.backup`，构建脚本以后也按此命名；清除该 bundle ID 的失效授权并重新选择当前 `dist/WallpaperUI.app` 后，系统列表显示 `WallpaperUI` 开启，真实桌面播放成功。原场景素材文件没有修改。本次没有开展多屏、长时稳定或第二张场景的 Space 动画验收。
