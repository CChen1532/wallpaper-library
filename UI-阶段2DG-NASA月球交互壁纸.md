# 阶段 2DG · NASA 月球交互壁纸

日期：2026-09-27；版本：0.2.55 预览，构建 2。

## 范围

用户提供 NASA SVS 14959，要求高级感、时间、互动、光影，并选择接入现有 macOS 壁纸项目。实现内置「SELENE · 月下观测台」：NASA 地形 GLB、真实本地时钟、固定柔和侧上方主光与暗部补光、4096 阴影贴图、鼠标主动旋转/缩放、持续慢速自转；不含模式切换与鼠标跟随。预览采用独立原生窗口，桌面播放复用 ScenePlayer；不更改已有 Mirage/视频渲染实现。

## 接入

新 MoonSceneRenderer 只执行随应用打包的本地代码。受限 moon:// URL scheme 不导航到外部网站；素材清单不能指定脚本或网页地址。离线资源包含 three.js r180 MIT 文件与 NASA 原始模型。素材来源/哈希见 `Scenes/LunarObservatory/asset-manifest.json`。

保持原播放协议：首帧完成后 ready / first-frame-presented，延迟显示、activate/deactivate、截图、moveDisplay、暂停/恢复/速度、父进程 EOF 清理。新增独立预览入口，应用退出时回收其持有的预览子进程。

## 验证结果

- 原生 MoonSceneRenderer、WallpaperUI Release 编译通过。
- NASA 原模型完整下载，81,505,784 字节、2,021,340 顶点、1,015,808 三角面；SHA-256 `c4b65fb4df622a37fd75366c2ed9bf9e163e41c0fde178b3b27e31b0173e6953`。
- 完整 NASA 模型隐藏预览检查通过：时钟秒数、自动自转变化；暂停时渲染帧数停止；恢复、拖动旋转、滚轮缩放、固定光照、无模式控件、普通鼠标移动不改变模型姿态、松手后继续自转与 PNG 快照；关闭父进程输入后退出。证据：`dist/MoonReview-Rotation/verification.json`。
- 已目视检查固定光照的实际渲染图，月面地形与阴影可见，布局无宣传语/装饰性标题。图库封面来自该渲染器截图。
- 157 项场景播放集成回归通过，包括新增月球清单路由、未知预设拒绝与输入关闭参数。受限沙箱内既有生命周期测试曾等待超时，在真实 macOS 服务环境重跑通过。
- 172 项场景核心自检通过；打包目录 catalog 正确识别新场景，entry.desktopScenePlayable=true、nativeMoonScene。
- 英文本地化检查通过，en / zh-Hans 各 587 条。
- 0.2.55 Release 应用已构建、深度签名验证通过；打包 NASA SHA-256 及 Web 源码与工作目录一致。打包后的渲染器已真实打开可交互预览并成功截图。
- 当前截图：`dist/MoonReview-Rotation/00-preview.png`。旧 `dist/MoonReview/` 中的多模式图是中间方案，不再代表成品。
- 用户当前应用正在播放「角色素材」，未停止或替换该运行会话。新版应用产物与独立预览分别交付。
- 本轮没有修改系统桌面图片或执行 Space 过渡底图试验。

## 边界

光照与姿态为艺术预设，不宣称真实当前月相。30 FPS 是帧率目标，真实功耗、长时间运行、其他 GPU、多显示器热插拔和 Space 过渡仍需独立验收。模型为 NASA 原始地形资产，页面已说明极点收束伪影，未擅自改写模型。

## 交付与使用

构建产物：`dist/WallpaperUI.app`。安装版 `/Applications/WallpaperUI.app` 保持 0.2.54、继续当前桌面播放。月球独立预览已打开；用户准备切换时退出旧应用，再打开构建产物，图库中选择「SELENE · 月下观测台」。本轮未对原系统桌面图片进行写入，也未把预览验证冒充桌面/Space 过渡验收。
