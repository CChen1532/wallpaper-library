# 阶段 2CM：设置页中英文界面切换

日期：2026-09-26。版本：0.2.35 预览。

设置页新增“应用语言”，支持简体中文和 English，默认简体中文。选择保存在 `appLanguage`，SwiftUI 根视图的 Locale 随之更新；运行时拼接的标题和状态文案通过 `AppStrings` 查找英文资源。两份 `Localizable.strings` 各有 248 个对应键。素材名称、路径和场景包提供的未知字段保留原文，避免误译用户内容。

构建时将 `en.lproj`、`zh-Hans.lproj` 打进应用。打包直接复制已纳入 Git 的 `AppIcon.icns`：本机 `iconutil` 连从有效 ICNS 反解出的 iconset 也报 `Invalid Iconset`，复制既有图标可稳定构建。版本号升至 0.2.35。

验证：Release 构建、应用深度签名、9 项渲染器输入策略检查、13 项图库导航检查通过；两份字符串表和 Info.plist 均通过 `plutil -lint`，资源键各 248 个且无重复。安装到 `/Applications/WallpaperUI.app` 后，设置页、窗口标题、侧栏、图库、场景详情可在中英文之间即时往返；“头发飘动”的辅助功能名称也切为 Hair Sway。切换期间角色素材4K 场景保持“正在桌面播放”状态。此处是应用 UI／状态验收，不等于逐帧画面或长时间播放验收。

旧安装包与旧构建保存在 `dist/.WallpaperUIPrevious/`。本轮未修改素材包、场景渲染和播放后端。
