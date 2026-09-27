# 创意工坊链接下载首版

日期：2026-09-27。版本：0.2.42 预览，构建 1。

## 范围与使用

侧栏增加“创意工坊”，设置页增加入口，菜单快捷键为 Command-Option-W。粘贴 Wallpaper Engine 创意工坊链接或数字 ID 后读取标题、封面和体积。现有资料库中同 ID 的素材文件夹直接显示已入库；其余项目使用自己的 Steam 账号下载，完成校验后加入“全部壁纸”。本轮保留现有场景与视频播放实现。

首版支持场景和 MP4 项目；全文搜索、筛选与订阅同步属于下一阶段，界面未添加占位控件。网页、应用和合集不导入。本轮没有新启动桌面壁纸，应用更新前处于待机状态。

## 实现

- `WorkshopURLParser.swift` 改编自 Loomscreen 的 MIT 实现，固定引用提交 `9b40a6d74de8cc1d0c5e5ddb82d132f3804282f1`。额外拒绝重复 ID 参数、非 ASCII 数字和超长输入。原始 MIT 许可及出处在 `Resources/Licenses/`，随应用打包。
- `WorkshopCore.swift` 使用 Steam 公开详情接口，无需 Web API Key；核验项目 ID、结果码与 app ID 431960。响应读取有大小限制，远程封面限定 HTTPS Steam CDN。
- `WorkshopSteam.swift` 从 Valve HTTPS 地址获取 macOS SteamCMD 引导包，对照本轮核验的 SHA256 再解包。组件独立存放，不捆绑进应用，也不运行下载的 shell 脚本。自更新退出码 42 最多重启两次；本机实际经历两次更新后启动成功。
- 登录密码与 Guard 代码只通过关闭回显的 PTY 输入，不放入命令参数或应用日志。界面使用安全输入框；仅记住登录账号名和用户选择的组件路径。SteamCMD 自身可以在应用的独立 HOME 下保留会话；未实现账号管理或会话清除页面。
- 应用生命周期持有下载任务，切换页面不会丢失任务；取消和退出会通知 worker，限时终止它自己启动的子进程。原始 Steam 输出只在内存中有界解析，不显示到 UI。
- 下载目录在 `~/Library/Application Support/WallpaperUI/Workshop/Staging/`，完整入库目录为其兄弟目录 `Library/<Workshop ID>/`。检查 `project.json`、声明媒体、普通文件、符号链接和路径边界后，同卷移动到隐藏暂存目录，再原子重命名发布。扫描器不会看到未完成文件，也不重复拷贝大型下载。
- 原有素材文件夹按数字 ID 识别已入库；其他位置的改名副本没有做内容哈希去重。已入库项目保留稳定路径与独立设置，本版不覆盖更新现有文件。
- `WorkshopModel.swift` 管理查询、组件准备、登录、下载、导入和取消状态；`WorkshopView.swift` 沿用系统字体、语义色、原生表单与按钮，提供中英文。

## 本轮验证

1. `bash scripts/check-workshop.sh`：最终 76 项通过。覆盖有效／伪造／歧义链接、错误 app、合集、损坏响应、路径穿越、符号链接、空媒体、取消前不入库、稳定 ID 去重、下载后现有扫描器可见、含特殊字符的密码、分段 PTY 提示、Guard、手机确认状态、失败退出、取消后子进程消失、超时、自更新重启与上限。
2. 带 `--live` 的检查实际读取 ID `1000000001`，返回“测试场景B”；从 Valve 下载引导包，SHA256 与解包校验通过。后续 GUI 还实际读取 `2360329512` 的标题、封面和体积。
3. 安装版点击“准备下载组件”成功。无账号启动探针观察到两次退出码 42；第三次退出码 0，显示 Steam Console Client 1788292693，加载／卸载 Steam API 成功。更新后的组件含 x86_64 和 arm64。探针不等于已登录或已下载壁纸。
4. 本地化：457 对资源键一致，509 条源代码中文文案有英文条目；9 项运行时检查通过。实际 UI 已检查中英文工坊页、错误提示、设置入口，并恢复简体中文。
5. Release 打包、内置运行时校验、9 项渲染器输入策略与深层签名检查通过。最终 `dist` 与 `/Applications/WallpaperUI.app` 主程序 SHA256 相同：`213d4d9b6cf380464c40bfaf6d3753d222588bf9a3c6fa07816814965c04cb2a`。
6. 实际 UI：测试场景B显示“已加入资料库”，图库保持 33 项；伪造 Steam 域名被拒绝；未入库项目显示账号／密码表单，未填写账号时下载按钮不可用。截图检查显示标题、封面、表单与组件区布局正常。

## 验收边界与恢复

真实账号登录、真实 Steam Guard、受授权素材下载及实际内容入库后播放尚待用户操作；模拟协议测试不能代替这一闭环。用户本轮明确选择“先保留预览版，稍后验证”，因此首版保持预览标记。用户无需在聊天发送密码，应仅在应用安全输入框完成操作。

工作树原有的四份未跟踪 WE 文档保留未改。旧安装版备份：`dist/.WallpaperUIPrevious/Installed-before-workshop-20260927-150623.app.backup`。组件初始引导包 SHA256：`8ecc17c8988e5acadcc78e631c48490f76150f2dfaa6cf8d7b4b67b097bd753b`；若 Valve 改包，本版会拒绝安装，需要先审查并更新固定摘要。

原有“壁纸素材”默认目录缺失提示在更新前已存在，本轮未更改这些目录或原始素材。未执行仓库网页中的安装／构建命令，未替换渲染器，未使用第三方共享账号。

## 参考

- [Loomscreen](https://github.com/Paradox07127/macos-wallpaperengine)，URL 解析及下载流程的架构参考。
- [固定版本 URL 解析源码](https://github.com/Paradox07127/macos-wallpaperengine/blob/9b40a6d74de8cc1d0c5e5ddb82d132f3804282f1/LiveWallpaper/Infrastructure/Workshop/WorkshopURLParser.swift)。
- `scripts/check-workshop.sh --live` 为本项目编写的验证入口；仅查询公开详情并校验组件包，不登录账号、不下载受授权壁纸。
