# 快速切换墙纸与复原（本机预览工具）

不必手动切换 Space。默认处理显示器 1 的桌面 1、2，把已经生成的 Scene 静帧设为系统过渡底图；复原使用切换前的完整壁纸记录，包括航拍 assetID、配置和图片选项。Scene 动态播放仍由原软件负责，本工具不启动或停止它。

## 双击入口

- `快速切换底图.command`：备份原记录，然后应用底图。
- `恢复原壁纸.command`：恢复上一轮记录；也可在定时等待期间提前复原。
- `临时切换60秒.command`：应用底图，60 秒后自动复原；Ctrl+C 或正常终止也会进入复原。

默认图片为项目 `dist/SpaceTransitionDiagnostics/scene-transition.heic`，来自样本 1000000001 的真实离屏帧。它是静态过渡底图，包含捕获时的时钟；不能当成动态壁纸播放器。缺少图片时明确报错，不会改设置。

首次执行如缺少 Space 查询程序会自动编译，需要本机已有的 Command Line Tools。已在本机编译完成。脚本由 Terminal 运行，若 macOS 提示访问相关文件，按系统实际提示处理。

## 命令行

在本项目根目录运行：

```sh
python3 工具/快速墙纸/wallpaper-switch.py apply /绝对路径/图片.heic --spaces 1,2 --display 1
python3 工具/快速墙纸/wallpaper-switch.py restore
python3 工具/快速墙纸/wallpaper-switch.py timed /绝对路径/图片.heic --spaces 1,2 --display 1 --seconds 60
python3 工具/快速墙纸/wallpaper-switch.py status
```

`--spaces all` 可以选择指定屏幕的全部普通桌面；全屏应用 Space 不计入编号。编号采用调用瞬间的实时排列，macOS 自动重排可能改变编号。保存后按 UUID 复原，所以随后重排不会把原配置写错桌面。`--display` 省略时使用主屏。默认双击入口固定显示器 1，连接变化时可调整脚本或使用命令行。

## 保存与恢复

- 首次系统写入之前，完整原始 `Index.plist` 已复制到 `dist/WallpaperQuickSwitch/<时间>/original.plist`，并记录 SHA-256。
- `dist/WallpaperQuickSwitch/session.plist` 保存每个目标的原 Desktop 字段与本次写入字段；这个文件与备份必须保留至复原完成。
- 只修改 `Spaces/<UUID>/Displays/<显示器UUID>/Desktop`，不写 Idle、其他桌面、全局选择或系统默认值。若全局壁纸覆盖开启、目标结构不支持或目标记录消失，会停止并报错。
- 复原会合并到最新配置中。其他桌面或屏保在期间发生的调整会被保留；若目标壁纸被用户再次更改，会报告冲突，保留恢复文件，不强行覆盖。
- 文件写入使用临时文件、fsync 和原子替换；本工具实例间加锁，写入前检查观察到的并发变化。WallpaperAgent 不遵守本工具锁，因此检查与替换之间仍有极短竞争窗口，不是系统级事务。
- 每次成功写入后仅请求重启当前用户的 WallpaperAgent 来重新载入；不重启 Dock、不修改安全设置、不操作 phonto。
- 定时等待不占用锁，“恢复原壁纸”可以提前复原。旧计时器不会恢复后来新建的会话。
- 强制杀死进程、掉电或系统刷新失败时，记录仍在，重新运行“恢复原壁纸”。没有安装后台服务，因此不能保证进程被 SIGKILL 后仍按时复原。

## 状态与限制

这是适配本机 macOS 15.8 的独立预览工具，使用 Apple 未公开的壁纸存储格式和只读 Space 枚举。已完成编译、语法检查、只读 Space 解析，以及临时假配置的恢复逻辑检查。按用户要求没有继续实际切换/动画验证，尚不能声称已经消除闪现、保证恢复在 0.5 秒内，或证明 WallpaperAgent 在所有系统版本都会按预期载入。

工具的“已写入/已复原”表示配置写入完成且刷新请求已发出，不代表逐帧画面验收。本工具尚未接入 WallpaperUI 的播放/停止按钮。

实现参考是本机真实配置字段，另只读参阅 公开的 WallpaperAgent 存储字段说明。未下载或执行其代码；本工具采用逐显示器/Space 字段恢复，不采用全局覆盖和整文件回滚。
