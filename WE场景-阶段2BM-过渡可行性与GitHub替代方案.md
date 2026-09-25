# 阶段 2BM：Space 过渡可行性与 GitHub 替代方案

2026-09-25。用户要求现在验证实际可行性，并从 GitHub 查找其他方案。本轮保持 0.2.10 应用与原系统墙纸，不把代码、设置读回或仓库宣传当作 Space 动画验收。

## 本机可复现结果

- 测试前系统设置显示原“默认系统壁纸”，`在所有空间中显示`关闭；恢复账本为 `restored`，`Index.plist` 全局 `Type=idle`、17 个 Space、全局无 Scene Desktop 选择。
- 在 UI 中启动已选的 `[若叶睦]测试场景C`，应用立刻提示“当前没有可用显示器”。独立只读查询同时得到 `NSScreen.screens.count=0`、`CGGetActiveDisplayList` 活动显示器数 0；系统显示器报告只有 Apple 测试机 GPU、没有显示器条目。失败点是选择显示器，**早于场景截图、系统壁纸写入及渲染启动**。
- 失败后再次读取恢复账本和系统配置，仍为 `restored`、`idle`、17 个 Space；原系统墙纸未被本次试验替换。本轮没有可供切换的活动显示器，因此无法做 Mission Control 缩略图或 Space 动画的真实目视验收。
- 前轮 0.2.10 的受控试验是一败一成；成功时独立 PNG、系统设置预览和全空间字段相符，停止后可恢复。但 100 ms 采样记录 `individual → idle → individual`，约 1.6 秒才再次稳定。当前 `SpaceWallpaperSettingsController.waitForSystemState` 见到第一次匹配就返回，尚不足以证明启动时底图持续有效。

## GitHub 源码与 Apple API 边界

| 路线 | 查到的实现 | 对本问题的判断 |
| --- | --- | --- |
| 系统原生静帧 + 第三方动态层 | [SakuraWallpaper](https://github.com/yueseqaz/SakuraWallpaper/blob/main/WallpaperManager.swift) 把视频帧截图经 `NSWorkspace.setDesktopImageURL` 登记为系统桌面图；[ScreenPlayer](https://github.com/yueseqaz/SakuraWallpaper/blob/main/ScreenPlayer.swift) 用 `.stationary`、`.canJoinAllSpaces` 的桌面窗口播放视频。 | 与本项目的“静帧承接动画、动态层正常播放”方向相符。其代码没有解决 macOS 全空间开关：Apple 工程师明确称目前[没有设置某屏所有 Space 图片的公开 API](https://developer.apple.com/forums/thread/834630)。其 Mission Control 宣传不能代替本机逐帧验证。 |
| 每个 Space 独立动态选择 | [LiveWallpaper 的 Space 映射](https://github.com/Narcissus-tazetta/LiveWallpaper/blob/main/Sources/LiveWallpaper/Core/Models/WallpaperModel%2BSpaces.swift)按 Space UUID 选视频；[CGSSpacesBridge](https://github.com/Narcissus-tazetta/LiveWallpaper/blob/main/Sources/LiveWallpaper/Core/Services/CGSSpacesBridge.swift)通过私有 SkyLight 读取当前 Space。 | 可借鉴“Space UUID → 场景身份 → 独立截图”模型，适合不同 Space 不同壁纸。但其[窗口刷新代码](https://github.com/Narcissus-tazetta/LiveWallpaper/blob/main/Sources/LiveWallpaper/Core/Models/WallpaperModel%2BWindowRefreshScheduling.swift)明确记载 `activeSpaceDidChange` 在切换动画后才到达；收到通知再换视频，无法预先覆盖动画帧。私有符号还需按系统版本降级。 |
| 仅用跨 Space 桌面窗口 | [LiveWall](https://github.com/Ostailor/LiveWallpaper_Mac/blob/main/Sources/LiveWall/WallpaperWindow.swift) 的桌面层 NSPanel 加全 Space 标志；[Lattice](https://github.com/bryancostanich/lattice) 记录第三方窗口不能在系统过渡合成器中持续绘制，减弱动态效果只减少闪烁。 | 本项目 2AS/2AZ 真实切换仍露出山脉，重复窗口层级/标志组合没有足够新证据。不能以仓库 README 的“seamless”推断本机动画已通过。 |
| 直接写系统墙纸私有数据库 | [wallall](https://github.com/TresChar/wallall/blob/main/wallall) 备份并改写 `Index.plist` 的全局 Desktop，再重启 WallpaperAgent。 | 本机此前只写私有记录及刷新代理/Dock 后，用户看到的 Mission Control 缩略图仍是旧森林；在系统设置真正操作“在所有空间中显示”才变为庭院。不同版本数据库语义也可能变化，不采用直接写文件作为独立成功路径。 |
| 把视频注册成系统 Aerial | [CaveWall 的登记器](https://github.com/Vahsir7/cavewall/blob/main/CaveWall/SystemAerialRegistrar.swift)转码 HEVC、改写私有 Aerial 清单和 `Index.plist` 的 `linked` 全局选择，并清空显示器/Space 覆盖。 | 这比桌面窗口更接近系统原生合成，但仓库自己声明使用未公开内部结构；本机是 macOS 15.8，而另一个 [Aerial Manager](https://github.com/kimmjen/aerial-manager)明确只支持 macOS 26 的用户可写 Aerial 目录。CaveWall 的全局覆盖还会破坏不同 Space 的独立选择。本轮只列作高风险研究方向，不在用户原配置上试跑第三方代码。 |
| 缩短/去掉切换动画 | [Lattice](https://github.com/bryancostanich/lattice)建议开启 macOS“减少动态效果”，并说明可把横向滑动改成接近瞬时切换。 | 可作为用户自愿开启的视觉缓解措施，不能满足“每张壁纸有匹配底图”，也不能当根因修复。 |

## 技术结论与下一次实测门槛

最有根据的主路线仍是“每张 Scene 自己的真实截图 + 系统原生静态底图 + 动态渲染层”。它有机会让系统过渡合成器显示匹配图，但当前自动化存在可观察到的配置回退，**尚未证明在完整 Space 动画中可行**。全空间单张图片也只适用于同一时刻所有普通桌面共用一个 Scene；若目标是每个 Space 同时有不同 Scene，必须另外实现 Space UUID 级的静帧登记与分别恢复，不能用一个全局静帧冒充逐 Space 匹配。

恢复至少一台活动显示器后，只进行有界试验：先读取原系统设置/备份/Space 数和场景身份；启动 A，要求全空间配置连续稳定超过已观测 1.6 秒回退窗口，再目视 Mission Control 缩略图及两个方向的真实 Space 切换；停止并核对原配置恢复。随后对不同图像的 B 重复，核对其独立 PNG 不复用 A，并再次恢复。一次静态缩略图正确不算动画通过。若不能自动获取动画过程帧，应保留用户目视结论为单独证据，不虚构逐帧结果。
