# WE 场景阶段 2O：只读场景目录验收

日期：2026-09-24。仅扫描显式传入目录；未修改原样本、应用或桌面壁纸。

## 实现

`WESceneInspection.catalog(directory:maxPreviewDimension:)` 和 CLI `catalog` 只查指定根目录的一级子目录中的 `scene.pkg`。根目录及子目录/包文件若为符号链接则拒绝或跳过；目录最多1000条、场景包最多20个、单包上限128MiB、受限预览最长边960像素。包逐项报告能力或错误，单个损坏包不阻断其他包。总报告和每包能力均不宣称桌面 scene 可播放。CLI 输出 JSON 后退出 3（预期的播放能力降级）。

## 验证

- 合成夹具：验证排序、符号链接跳过、损坏包隔离、有效包受限静态预览、根目录链接拒绝；`bash scripts/check-scene.sh` 149 项通过。
- 真实目录 `/Users/you/Movies/Wallpapers2` 执行 `catalog … 480`：发现 5 个包，版本分别 PKGV0018、0021、0022、0023、0024；`1000000001`、`3483456356`、`1000000006`、`3584071721` 的受限静态预览可用，`3415680813` 不可用。五包均可检查资源、均报告桌面动态 scene 播放为 false；返回码 3 符合设计。
- `swift build --disable-sandbox --target WESceneCore` 和 `bash scripts/check.sh` 通过，后者为34项现有前端回归。

## 边界

这个目录报告仍是独立工具与核心接口，未接到现有 UI。`restrictedStaticPreviewAvailable=true` 不代表画面忠实或可以动态播放；不能使用现有 phonto 视频控制入口播放 scene 包。
