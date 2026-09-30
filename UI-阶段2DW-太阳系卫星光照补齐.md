# 阶段 2DW：太阳系卫星光照补齐

日期：2026-09-30。交付为 0.2.70（构建 2）太阳系修复预览；基于当前安装包制作，仅替换 SceneRuntime 并重新签名。应用主程序的 `__TEXT/__text` 与当前安装的 0.2.70 一致，现有多屏源码改动保留。2026-09-30 按用户要求安装到 `/Applications/WallpaperUI.app`，安装读回为 0.2.70（构建 2）。

## 已复现的问题

2DL 的 14 个初始焦点覆盖行星与矮行星，遗漏了 22 个天然卫星。当前安装的 0.2.70 确实包含原光照补丁，但月球在隐藏渲染中仍接近纯白，木卫一近黑。为卫星接入光照分支后，全量检查还发现土卫一亮面过曝。

## 修复

- 在原有太阳系精确识别条件内，补齐月球、火星两颗卫星、木星四颗、土星七颗、天王星五颗、海王星两颗及冥王星一颗卫星的 `generic4` 材质组合。
- 月球与火星使用较强的高光压缩，其余卫星使用普通压缩和背光补偿。
- 太阳系使用法线贴图的材质，在切线空间转到世界空间后归一化法线。土卫一的高光异常由未归一化向量触发，对照修正后亮面纹理可见；仅增大压缩分母不能解决。
- 原素材、作者脚本与用户存储没有修改；识别条件未放宽，其他壁纸保持原着色器路径。太阳系补丁保存在 `patches/mirage-solar-scene-load.patch`，复用已钉住的 Mirage 源码。

## 验收

`scripts/check-solar-renderer.py` 在同一隐藏进程中遍历 36 个焦点。只改临时 APFS 素材副本的诊断入口，以素材原有的母星→卫星规则切换；记录实际二进制和着色器 SHA-256，并逐项等待焦点稳定后截图。不能将成功截图等同于画面正确，另行查看全部对照图。

- 最终签名包：14 个行星/矮行星/太阳概览焦点及 22 个卫星焦点全部收到稳定状态并截图，人工检查纹理、高光和背光。月球、木卫一及土卫一原问题消失，行星材质仍可辨识。
- 实际包内渲染器 SHA-256：`8a718d02ebd19ece75e3ea37bbfa69242d1085ebea579cd5b45b590ff520cf21`；与运行时清单相符。全量检查 69.83 秒，退出 0，未激活窗口，原素材 SHA-256 前后相同。采样画面实际为 640×500（Host 有最小高度限制）。
- CTest：6 项通过，WallpaperPosition 按环境条件跳过；9 项输入策略检查通过。补丁正向应用、隔离源码反向应用、源构建检查及 `git diff --check` 通过。最终 App 深度严格签名检查通过。
- 本轮没有修改 Swift UI/播放协调源码，没有将其他任务未提交的多屏改动混入修复提交。

证据：`dist/solar-satellites-20260930/report.json`、`comparison.jpg`、`before-after.jpg`、36 张 PNG 和 `renderer.log`。预览包：`dist/WallpaperUI.app`，独立副本：`dist/SolarSatellitePreview-0.2.70-build2/WallpaperUI.app`。原构建备份：`dist/.WallpaperUIPrevious/Built-0.2.70-build1-before-solar-satellites.app.backup`。

## 验证边界与后续

当前只完成真实素材隐藏窗口验收，未进行桌面播放或 Space 切换验收，也未覆盖所有日期、相机角度、航天器及长时运行。用户本轮要求安装，安装前 UI 为桌面待机且无壁纸渲染进程；正常退出应用后替换安装包，再打开应用，35 项素材加载完成且保持桌面待机。安装后深度严格签名检查通过，实际 SceneWallpaper SHA-256 与上述验收包一致。旧安装包保存在 `dist/.WallpaperUIPrevious/Installed-0.2.70-build1-before-solar-satellites.app.backup`。本轮没有启动桌面试播；后续桌面试验需另行明确授权，范围包括显示器 3 的 16 个 Space 底图及结束后的原壁纸恢复核对。

只读复用研究：继续使用 [MirageWallpaper](https://github.com/laobamac/MirageWallpaper) 当前已核验的源码链，没有下载或执行网站命令。
