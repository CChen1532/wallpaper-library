# Scene 阶段 2C：受限静态基础图合成

日期：2026-09-23。状态：已验证的离线预览实验，**不是 Wallpaper Engine 场景播放器，也未接入桌面/UI**。
前置版本：`86afc9f` / `scene-stage2b-preview.1`；本阶段提交与标签以 Git 日志为准。

## 实现范围

- `WESceneInspection.staticPreview(packageData:maxDimension:)` 只接受包数据，输出 RGBA 与版本化诊断 JSON；`we-scene-probe still <scene.pkg> <out.png> [max-edge]` 写出 PNG 和同名 JSON。默认最大边 1600，允许 1-4096，PKG 输入上限 256 MiB。
- 基于正交投影，将单 pass、单颜色纹理的 image 图层合成到画布；实现父子二维平移/旋转/缩放、可见性、图层 alpha、标准 source-over、图层顺序及纹理有效尺寸裁剪。仅接受已知普通混合模式；shader `genericimage2/4` 只是基础贴图近似。
- 每个跳过或降级项带图层位置和原因。脚本/用户属性仅取静态默认值，效果器、粒子、文字、音频、3D 投影、非普通 blend、缺失/包外资源均不执行或不假装支持。`playable=false`、`faithful=false`；`previewAvailable` 仅表示至少一个基础 image 层被合成。
- 发现真实 TEXB0003/0004 样本的 `-1` 裸像素标记内实际嵌入 MP4：载荷偏移 4 处是 `ftyp`。解析器现在把它识别为视频纹理，静态解码/缓存明确拒绝。未标记视频的裸 R8/RG88/RGBA8888 也要求精确字节数，不能截取 MP4 前段伪造图像。
- 若没有可合成的静态 image 层，CLI 仅写诊断 JSON，退出 3，不新生成 PNG。重新对同一路径运行前应留意可能存在的旧 PNG；CLI 不自动删除已有用户文件。

## 验证

- `bash scripts/check-scene.sh`：106 项合成测试通过，0 失败；含二维坐标、父级矩阵、Y 轴、alpha、顺序、裁剪、非法变换、未知混合、效果遗漏、视频伪装载荷和超长裸数据。
- `bash scripts/check.sh`：现有 phonto 视频前端 34 项通过。`swift build --target WESceneCore` 通过。
- 样本 `3483456356`：960×540 基础图可生成；13 个图层合成，5 个 image 图层跳过；人物 MP4 层被跳过。目视检查已无先前的随机噪点，樱花背景与静态前景可见。文件在本任务的 `outputs/scene-stage2c/3483456356.png` 和 `.json`，不纳入 Git。
- 样本 `3415680813`：主 image 层为伪装 MP4；0 个 image 图层合成。CLI 退出 3，仅生成 `outputs/scene-stage2c/3415680813.json`，不提供可用 PNG。先前由错误解析产生的测试 PNG 已从本任务输出目录删除；原 scene.pkg 未改动。
- 这两个场景的画面均**未**与 Wallpaper Engine 播放时的真实逐帧结果对照；静态近似图不能证明视觉等效、动画或桌面可播。

## 复现

```sh
bash scripts/check-scene.sh
bash scripts/check.sh
swift build --target WESceneCore
bash scripts/scene-probe.sh still /absolute/path/scene.pkg /tmp/scene-preview.png 960
```

`still` 参数错误退出 2、无可合成层退出 3、包或输出错误退出 1。`resources` 继续用于独立资源能力审计，不能以 `still` 成功代替完整能力判断。

## 后续阶段

先从真实样本和公开格式依据研究 MP4/TEX 视频纹理的播放时序、图层 shader/effects 与运行时依赖，再决定最小动态 scene 渲染闭环。必须继续隔离 UI 与渲染核心，且只有实际桌面画面持续运动并通过场景能力/降级验收，才可称为 scene 适配完成。不要把本阶段静态图直接接到“设为动态壁纸”。
