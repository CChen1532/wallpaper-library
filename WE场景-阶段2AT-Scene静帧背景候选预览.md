# 阶段 2AT：Scene 静帧背景候选（未改系统壁纸）

日期：2026-09-25（Asia/Kuala_Lumpur）

## 问题与候选

2AO、2AS 的 Stationary 窗口在 Space 切换完成后跟随正常，但动画中会短暂露出旧系统桌面；2AQ 的 Managed 行为则把 Scene 当作普通窗口缩略图。仅调整窗口集合行为或层级均未解决。Mirage v1.1.4 自身的 `DesktopOverrideService` 还有一条静帧路径：向 SceneRenderer 请求当前合成帧，然后把它设为 macOS 的真实桌面图片，结束时恢复原图。当前项目此前只移植了 SceneRenderer 跟随窗口，未接入该路径。

2AT 先建立**不改系统壁纸**的独立证据：桥接器向已有 Mirage `snapshot` 控制命令发送 UUID 请求，核对 `snapshot-done` 中同一 token 的成功/失败状态；新 `--capture-still` 命令在透明且未激活的渲染窗口中取得一帧，校验图像尺寸后原子移动到指定的新 HEIC 文件。它不调用 `NSWorkspace.setDesktopImageURL`。失败或超时会停止自身创建的渲染进程、删除临时图片，不触碰 phonto。

## 已验证

- Release 构建成功；桥接自检覆盖静帧成功与失败回复，原生命周期、焦点交接和清理检查仍通过。
- 使用既有 `MirageFocusFollowRuntime` 和真实 `3483456356/scene.pkg`，在内置显示器 1 的透明窗口中导出 `dist/SceneStillPreview-3483456356.heic`。ImageIO 识别为单帧 2880×1864；文件为 746,661 字节 HEIC。转成临时 PNG 目视可见完整人物/樱花 Scene 画面，非系统山景；导出没有执行 `activate`。
- 导出后没有 SceneWallpaper/桥接器残留。只读 `NSWorkspace.desktopImageURL(for:)` 前后均为 `/System/Library/CoreServices/DefaultDesktop.heic`；这仅证明本次没有修改系统桌面图片。

## 下一次实机试验的事务边界

下一步如获明确许可，先在系统设置中记录原始壁纸选择、外观选项及“在所有 Space 上显示”状态；把本次静帧放到持久位置，再通过 macOS 壁纸设置将其选为背景并开启“在所有 Space 上显示”。Apple 的[壁纸设置说明](https://support.apple.com/guide/mac-help/mchlp1103/mac)说明此开关使所有桌面 Space 和显示器使用同一壁纸；而 [Apple 框架工程师](https://developer.apple.com/forums/thread/834630)说明公开 API 没有一次设置所有 Space 图片的接口。因此不通过写 WallpaperAgent 私有数据库绕过该边界，也不把 `NSWorkspace.setDesktopImageURL` 当作全 Space 操作。

只在确认背景已同步后，另行运行一次最长 60 秒的旧 Stationary 跟随 Scene 试验，观察进入 Mission Control、切换到另一个 Space 和返回的动画、图标及停止清理。试验后按记录恢复原壁纸及原“所有 Space”开关状态，并核对系统壁纸 URL、Scene 进程和 phonto 状态。若系统设置无法明确恢复原状态，须停止桌面试验并先处理恢复。静帧只是动画期间的画面匹配候选，**不是动态 Scene 在动画里继续播放的证明**；正式 Scene 仍保持关闭。
