# 壁纸库

macOS 14+ 原生 SwiftUI 壁纸前端，当前后端为已有的 phonto-wall。打开 `dist/WallpaperUI.app` 即可使用。首次访问桌面目录时请允许系统权限请求。

## 构建与验证

```sh
bash scripts/build-app.sh
bash scripts/check.sh
bash scripts/check.sh --live
```

需要 Swift 5.9+ / Apple Command Line Tools，无第三方依赖。`--live` 读取真实素材并写入缩略图缓存，不改变播放状态。构建产物与缓存不进入 Git；应用使用本地 ad-hoc 签名，尚未公证。

## 使用

- 单击卡片选择，点击“播放所选”开始播放；底部提供上一张、随机、下一张。
- “停止”保留轮播，定时任务可能再次播放；“全部关闭”同时关闭轮播。
- 导入会复制 MP4 到已有素材目录，同名文件跳过并提示，不覆盖。
- 删除需要确认，文件移入废纸篓。若该文件正在播放或轮播开启，会先全部关闭。
- 预览缓存位于 `~/Library/Caches/WallpaperUI/Thumbnails`。

## 当前限制

- 本机脚本的 `rotate on` 分派只传递间隔，没有传递模式，因此 UI 暂仅开放随机轮播。底层脚本未被修改。
- `start` 的返回码可能被脚本后续逻辑覆盖；前端会在完成后核对实际运行状态和路径。
- 还未支持显示器列表、详细解码负载、菜单栏、开机启动以及 Wallpaper Engine 场景解析/渲染。
- `WallpaperBackend` 协议与资源类型字段作为后续适配入口；现在仅实现 phonto 视频。
- 配置路径与现有控制脚本保持一致。更换素材位置前需要同步后端配置。
- 状态四秒刷新一次；首次预览生成逐个处理，避免同时解码多个 4K 视频。
- XCTest 在本机 Command Line Tools 环境不可用，因此使用独立 Swift 断言程序验证核心边界。

## 进度入口

