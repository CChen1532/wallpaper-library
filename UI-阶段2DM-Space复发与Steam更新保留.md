# Space 复发与 Steam 更新保留

2026-09-28；0.2.61 预览。

## 现场与原因

- 安装版原为 0.2.59，实际正在播放测试场景B；场景自动底图偏好为关闭，最近租约为 restored。系统仍采用之前的全空间静帧，不能随当前场景更新。
- 旧代码在兼容性检查失败后永久关闭偏好，随后仍启动没有底图的场景。现有记录不能区分此次关闭来自自动回退还是手动操作，但该代码路径可确定导致以后持续绕过底图。
- 当前 macOS 15.8 / 24H23 的墙纸结构是 AllSpacesAndDisplays=individual、Spaces/Displays 为空。旧实现仅允许 idle 的独立 Space 基线，错误拒绝这类原生全空间配置。
- Steam 订阅浏览器使用 nonPersistent WebKit 数据存储，订阅列表也仅保存在内存中，重启或更新后无法保留。

## 修改

- 增加当前实机全空间结构的精确指纹白名单，沿用系统版本与未知结构拒绝策略；完整保存原共享底图，停止后恢复原配置。
- 原生图片登记若临时展开 Space/显示器节点，仅在节点属于事前清单、图片为本次静帧且屏保选择未变化时回收；未知 Space、外部换图继续保留恢复记录并拒绝覆盖。
- 静帧登记同时接受稳定的独立 Space 和全空间形态。
- 场景底图不兼容时拒绝本次场景启动并显示原因，不永久改写用户开关。视频同样保留用户设置并显示失败，仍沿用原视频播放策略。
- Steam 页面使用 WebKit 默认持久存储。应用标识和签名身份保持固定，应用包替换不触及网站数据或 SteamCMD Profile。
- 账号名编辑后保存；订阅元数据和读取时间原子写入 Workshop/Subscriptions-v1.json，后台读取并恢复，界面标明是上次快照，需重新读取确认当前账号。
- 不保存 Steam 密码到应用偏好或订阅文件。旧临时网页会话无法迁移，升级后需再登录一次；Steam 端过期或撤销的会话仍需重新验证。

## 验证

- 163 项 Scene 集成检查通过，新增不兼容底图不能静默启动场景的回归。
- 49 项 Workshop 管理检查通过，含无网络条件下模型重建恢复订阅及账号名。
- 9 项离线租约检查、既有恢复检查、4 项恢复账本测试通过；共享基线往返、原生登记中断、外部修改冲突均覆盖。
- 当前显示器/Space 的只读兼容性预检返回 WALLPAPER_COMPATIBILITY_OK。
- 本地化检查通过：590 对资源键、630 条界面文案、9 项运行时断言。Release 构建、打包和严格签名通过。
- 受限环境的 Scene 测试因不允许写测试 SceneStorage 超时；允许对应目录写入后通过，未放宽超时断言。

## 交付与边界

- 已安装 /Applications/WallpaperUI.app 0.2.61；构建副本 dist/WallpaperUI.app。
- 回退包：dist/.WallpaperUIPrevious/Installed-0.2.59-before-0.2.61.app.backup。
- 已在应用设置重新开启场景自动底图。测试场景B实际启动后，UI 显示桌面播放，账本 applied，全空间静帧路径与租约一致；稳定确认 3.53 秒、1 次开关操作，16/17 个样本匹配。
- 停止后账本 restored，系统配置排除 LastSet/LastUse 时间戳后与本次启动前备份完全一致；随后恢复当前庭院场景播放。
- 离线检查和配置匹配不等于逐帧 Space 动画验收；Steam 真实账号跨更新登录保留还需真实登录会话，未代替用户登录。

## 只读研究

- [WebKit 的 WKWebsiteDataStore 接口](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.h)：采用持久存储，网站认证数据交给 WebKit 管理。
- [wallall](https://github.com/TresChar/wallall)：检索到其全空间配置路径；未执行仓库命令，沿用本项目已有的恢复账本与原生登记流程。
- DeepSeek 支持调用被参数校验拒绝，未重试或采用任何草稿；本次实现与检查由主代理完成。
