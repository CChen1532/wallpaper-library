# 阶段2CN：关于面板与英文界面补全

版本：**0.2.36 预览，构建1**（上一版 0.2.35）。日期：2026-09-26。

## 1. 目标

用户要求两件事：把应用里的「关于」写正式；把英文界面做完整。

## 2. 做了什么

### 2.1 「设置 → 关于」面板

原来只有「辅助功能授权 / 刷新授权状态 / 显示器与运行状态 / 版本」四项。现在补齐为：

| 条目 | 内容 |
| --- | --- |
| 应用 | WallpaperUI |
| 版本 / 构建 | 版本号 + 「预览版」后缀，构建号 |
| 版权 | © 2026 Cheng (CChen1532) |
| 许可说明 | 本应用源码 MIT；内置 Mirage 场景运行时 GPL-3.0 |
| 打开项目主页 | 打开 https://github.com/CChen1532/wallpaper-library |
| 在访达中显示许可文件 | 定位包内 `SceneRuntime/Contents/Resources/Licenses` |
| 复制版本信息 | 复制「应用 + 版本 + 构建 + macOS 版本」，便于反馈问题 |
| 辅助功能授权 / 刷新 / 显示器与运行状态 | 保留原行为 |

### 2.2 英文界面补全

审计 `Sources/WallpaperUI` 得到的 375 条中文界面文案中，原英文表只覆盖了 248 条，**缺 87 条**（多数是错误与边界提示，例如「无法定位系统墙纸的全空间开关，正在恢复原壁纸」「操作超时，请刷新确认实际状态。」）。

本轮：

1. **本地化表补齐到 335 条**（en.lproj 与 zh-Hans.lproj 键集合一致）。带 Swift 插值的消息以静态前缀为键，例如 `恢复原壁纸失败：` → `Failed to restore the original wallpaper: `。
2. **AppStrings 增加两种回退**：
   - 前缀回退：仅对以 `：`、`。`、`（`、`；` 结尾的条目生效，避免「停止」这类短词把更长句子切错；命中后保留动态尾部原文。
   - 数值 + 单位：`5 分钟`、`90 秒` 这类运行时拼出的字符串按 `%.0f 分钟` / `%.0f 秒` 输出为 `5 min` / `90 sec`。
3. **界面里 10 处动态提示改走本地化通道**（图库问题横幅、场景/视频底图提示、操作失败弹窗、场景包错误、视频详情提示等）。

### 2.3 应用名与权限说明的英文（实机验收后发现）

安装 0.2.36 后用辅助功能树核对英文界面，发现应用菜单仍是「关于壁纸／隐藏壁纸／退出壁纸」、AX 应用名为「壁纸」——因为 `CFBundleName` 来自 Info.plist，不随应用内语言切换。补 `Resources/en.lproj/InfoPlist.strings`：

- `CFBundleName` / `CFBundleDisplayName` = Wallpaper
- `NSDesktopFolderUsageDescription`、`NSAudioCaptureUsageDescription` 的英文说明（系统权限弹窗跟随）

### 2.4 新增验证

| 检查 | 内容 |
| --- | --- |
| `scripts/check-localization.py` | 静态：界面文案是否都有条目、en/zh 键是否一致、英文值是否残留中文 |
| `scripts/check-localization.sh` | 先跑静态检查，再编译并运行 `Tests/LocalizationChecks.swift` |
| `Tests/LocalizationChecks.swift` | 运行时 9 项断言：精确查找、短词误匹配防护、前缀 + 动态尾部、数值 + 单位、中文原样返回、未收录原样返回、空串 |

## 3. 验证证据

- `swift build`：**Build complete**（51.44s，0 错误）。
- `python3 scripts/check-localization.py`：375 条界面文案全部有条目（允许清单 6 条：正则片段与默认素材目录）；en 与 zh-Hans 各 335 条且键一致；英文值无中文残留（`简体中文` 为语言选择项，属预期）。
- `bash scripts/check-localization.sh`：运行时 9 项断言全部 PASS。

## 4. 边界与未完成

- **未重新打包安装**：本轮只在源码层完成并验证，`/Applications/WallpaperUI.app` 仍是 0.2.35；英文界面的逐屏目视验收需要重新打包安装后进行。
- 由系统或第三方返回的动态部分（命令输出、系统错误描述）保持原文，不做二次翻译。
- 素材自带标题、作者自定义文本、场景包内文字不翻译，这是既有约定。
- 默认素材目录仍写死作者本机路径（`Movies/Wallpapers`、`Movies/Wallpapers2`），对外发布前建议改为通用默认值，本轮未改动。
