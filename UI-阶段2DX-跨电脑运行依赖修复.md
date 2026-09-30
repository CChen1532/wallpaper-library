# 0.2.71 跨电脑运行修复预览

目标平台：Apple Silicon Mac，macOS 15 或以上。当前原生应用不支持 Windows；Intel 运行包未提供，也未声明支持。

## 修复内容

- phonto、phonto-winwait、ffmpeg、ffprobe 随应用打包。Swift 后端、缩略图与视频底图统一从应用 Resources 读取，安装版不回退到用户 `.local/bin`。
- 随包包含独立 CPython 标准库，移除运行时对系统 Python／Xcode Command Line Tools 的依赖；使用 `-I` 隔离外部 Python 环境和用户包。
- 新用户默认素材目录为 `~/Movies/WallpaperUI`，导入时创建；不存在的旧默认桌面目录不产生扫描错误。已有默认目录、显式添加来源以及移除来源记录继续保留。
- 视频显示器名称由包内本地辅助程序按 UUID 解析，避免应用中文名称和 CLI 名称不同造成无法播放；同名显示器继续明确拒绝以免播放到错误屏幕。
- 只读底图兼容性检查失败时继续播放并显示告警；底图实际激活失败，必须先成功恢复并确认没有待恢复记录才继续。恢复失败仍阻止启动并回收渲染器。
- 打包可以复用已经封装的 SceneRuntime，保留太阳系构建 2 的卫星光照运行时；已有应用在新包验证完成前保留。

## 构建

`PORTABLE_PYTHON_SOURCE` 指向含 `bin/python3`、`lib/pythonX.Y` 的可重定位独立 CPython。`MEDIA_TOOLS_SOURCE` 指向上述四个媒体工具，默认读取开发机 `.local/bin`；这些仅为构建输入，成品不依赖源位置。缺失输入直接停止构建。

`SCENE_RUNTIME_SOURCE` 可以指向已验证的封装运行时，或者本地原始运行时。二进制构建产物不进入 Git。GPL 和 CPython 许可说明随包保留。

## 验证与限制

- 47 项后端、21 项素材发现、20 项多屏协调、8 项脚本回归通过。
- 迁移到含中文和空格的临时路径、受控 PATH 和 Python 隔离环境；88 项检查覆盖全部 Mach-O 的 arm64 与外部 dylib 检查、独立 Python、ffmpeg／ffprobe、phonto 显示器枚举、控制入口和底图脚本离线导入。
- 修正最低系统声明为 macOS 15：包内 Vulkan／字体库／显示器工具要求 15，不能继续声明兼容 14。每次打包检查所有 Mach-O 的最低系统版本。
- 169 项场景回归通过，包含激活失败恢复成功／失败两种路径。
- 0.2.71 构建 1 已安装，UI 版本读回一致、图库显示 34 项可见素材、底图告警未显示，保持待机；太阳系渲染器哈希仍为 `8a718d02ebd19ece75e3ea37bbfa69242d1085ebea579cd5b45b590ff520cf21`。压缩包：`dist/WallpaperUI-0.2.71-arm64-macOS15.zip`。
- 未进行另一台实体 Mac 的全流程验收；迁移测试仍运行在当前 Mac，不能代替干净系统、热插拔、双屏同时动态播放或长期运行验收。
- 当前签名是本地证书，不是 Developer ID 公证发布包；其他 Mac 的 Gatekeeper 仍可能阻止首次打开。没有移除隔离属性或绕过系统保护。
- Steam 登录／下载依赖网络和 Valve 组件；Apple Silicon 上 Intel SteamCMD 还可能需要 Rosetta，尚未在无 Rosetta 的干净 Mac 实测。场景素材文件需要另行迁移或重新添加来源。
