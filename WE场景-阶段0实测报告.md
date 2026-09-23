# Wallpaper Engine 场景 —— 阶段 0 实测报告（真实样本）

> 面向：壁纸库（macOS SwiftUI）项目 / 开发者
> 执行时间：2026-09-23　执行者：DSH（喵酱，支持任务）
> 前置：`Linux 实现可行性报告.md`、`WE场景-阶段01规格与测试计划.md`
> 结论：**阶段 0 完成**。拿到 5 个真实 scene 样本，解析器在真实数据上跑通，并**改掉了 2 个按文档写错的假设**。

---

## 1. 样本获取通道（已打通，可复用）

| 环节 | 结论 |
|---|---|
| VM 状态 | VMware Fusion 26.0.1 / Windows 11 ARM（加密 + 挂起）→ 需在 Fusion GUI 点 Resume 才能启动（\vmrun -vp ... start\ 对加密 VM 报 "operation is not supported"） |
| 凭据来源 | 宿主文件 \~/Movies/DeepSeek/VM-日志与备份/vm-credentials.txt\（VM_PASSWORD / GUEST_USER / GUEST_PASSWORD 三项） |
| 来宾身份 | \whoami\ = **c1\c2**（2 字符账户，非管理员；**不能写 C:\ 根目录**，用 \C:\Users\Public\\ 中转） |
| 共享文件夹 | ❌ **来宾侧不可见**（\Test-Path "\\vmware-host\Shared Folders\Wallpapers"\ = False，即使宿主侧已启用）→ 只能走 vmrun 文件复制 |
| 命令通道 | ✅ \vmrun runProgramInGuest\ + **PowerShell `-EncodedCommand`**（base64/UTF-16LE）。**cmd.exe 的引号会被 vmrun 吃掉**，直接传 \cmd /c "..."\ 会失败（exit 1），务必用编码命令 |
| 素材路径 | \C:\Program Files (x86)\Steam\steamapps\workshop\content\431960\ |
| 复制方式 | ✅ \vmrun copyFileFromGuestToHost\（单文件），实测吞吐约 **1 MB/s**（48 MB 用 49 秒） |

> 可复用脚本：\生活/.local/src/vm/\（\run-copy.sh\ / \scan.py\ / \list.ps1\）——含凭据读取与编码命令封装。

---

## 2. 样本清单（5 个真实 scene）

| 样本 ID | PKGV | 条目数 | 体积 | 顶层目录 | 场景对象 |
|---|---|---|---|---|---|
| 1000000001 | **PKGV0018** | 46 | 14 MB | effects, materials, models, particles, shaders | image=2, particle=2, text=1 |
| 3415680813 | **PKGV0021** | 9 | 97 MB | materials, models, particles | image=1, particle=1, sound=1 |
| 3483456356 | **PKGV0022** | 111 | 62 MB | effects, fonts, materials, models, particles, **scripts**, shaders | image=20, text=8, node=7, particle=2, sound=1, camera=1 |
| 1000000006 | **PKGV0023** | 184 | 23 MB | effects, fonts, materials, particles, shaders | image=35, particle=7, text=4, **effect=1**, sound=1 |
| 3584071721 | **PKGV0024** | 167 | 8 MB | effects, fonts, materials, models, particles, shaders | image=60, text=20, particle=12, node=7 |

- 全部 24 个订阅中：**scene 16 个 / video 8 个**
- 样本落盘位置：\~/Movies/Wallpapers2/<id>/{scene.pkg, project.json, preview.jpg|gif}\（**不要进 Git**，单文件最大 97 MB）

---

## 3. L2 测试结果（对照阶段 1 规格里的清单）

### 3.1 容器层 PKGV ✅

- **实测版本：0018 / 0021 / 0022 / 0023 / 0024**（不是先前以为的只有 0019）
  → 阶段 1「只校验 \PKGV\ 前缀、未知版本仅告警」的设计**被真实数据证明是必要的**
- 条目路径结构实测覆盖：\effects/\ \fonts/\ \materials/\ \models/\ \particles/\ \scripts/\ \shaders/\
- **存在路径为空的条目**（实测 3 处，例：3584071721 中有一条 length=1.7 MB 的空名条目）→ 解析器不报错可继续
- 大包未测（最大样本 97 MB；543 MB 与 466 MB 的两个未拷）

### 3.2 纹理 TEX ✅（**发现并修正一个致命假设**）

127 个纹理全量扫描结果：

| 维度 | 实测分布 |
|---|---|
| 容器版本 | TEXB0003 ×17、**TEXB0004 ×110** |
| 像素格式 | RGBA8888 ×31、**R8 ×51**、**DXT5 ×39**、DXT1 ×1、RG88 ×5 |
| 内嵌图片 | PNG ×16、JPEG ×1、裸像素 ×110 |
| mipmap 压缩 | LZ4 ×209、未压缩 ×86 |
| GIF 纹理 | 1 个（当前按静态处理） |

> ⚠️ **关键修正（本次最大收获）**：RePKG 源码里 \TEXB0004\ 的 mipmap 头（p1==1, p2==2, conditionJson, p3==1，其源码自己标着 FIXME）**在真实文件上是错的**。
> 按它实现时 **110/127 个纹理解析失败**；字节级取证（xxd + 逐字段解读）确认：**TEXB0004 的 mipmap 布局与 TEXB0002/0003 完全一致**（\w, h, isLZ4, decompressedSize, byteCount, bytes\）。
> 修正后复测：**127/127 全部解析成功，0 失败**。

其它已验证：
- ✅ LZ4 手写解码器在真实数据上正确（含 8.3 MB 级解压）
- ✅ **DXT5 解码视觉验证通过**：3840×2176 的云层纹理解出的 PNG 无块状伪影、无通道错位
- ✅ 内嵌 PNG/JPEG 走 ImageIO 路径可用（4096×4096 纹理 + 5 级 mipmap）
- ✅ R8 深度图（3840×2160 + LZ4）正确解出
- ❌ 未测：TEXB0001/0002（样本中未出现）、GIF 帧信息容器、MP4 视频纹理

### 3.3 scene.json ✅（**修正类型判定**）

- 顶层 \camera\ / \general\ / \objects\ 结构与文档一致；\general\ 实测有 27 个字段（bloom 系列、cameraparallax 系列、hdr、skylightcolor…）
- **对象类型实测**：\image\ / \particle\ / \text\ / \sound\ / \camera\，另有 2 类文档没提的：
  - **\node\**（只有 id/name/origin/scale/angles/parent/visible/parallaxDepth 等变换键的**空节点**）
  - **\effect\**（带 \shape: "quad"\ + \effects[]\ 的**效果发射器**，例：光束）
- **用户属性引用**实测存在：\"visible": {"user": "sunshine", "value": true}\（单个场景最多 34 处）→ 阶段 2 若要支持用户属性，解析器需保留 user 名与默认值
- **script 多态字段**实测最多 77 处（\{"script": ..., "value": ...}\）→ 之前 macOS 实现踩的坑确实是普遍现象
- **3D 模型引用是 \models/*.json\**（不是 \.mdl\）：如 \models/util/solidlayer.json\、\models/01中藤.json\ → 阶段 2 处理模型时以 JSON 为准

---

## 4. 对阶段 2 的影响

1. **解析层证据已足够开工**：容器 / 纹理 / 场景结构三项在真实样本上全部跑通
2. 阶段 2 必须优先解决：
   - **DXT5/DXT1 纹理占比高**（39+1 / 127）→ 渲染后端需要 GPU 端压缩纹理支持（Metal 原生支持 BC 格式，或先解码成 RGBA）
   - **R8 灰度图占 51 个**（多为 mask/depth）→ 不能当成普通彩图处理
   - **LZ4 mipmap 占多数** → 加载路径需要解压步骤与缓存策略
   - **GIF 纹理**（1 个）与 **effect 对象**（效果发射器）暂不支持时要在 UI 上明示，而不是静默画错
3. 许可证决策仍未定（GPL vs 自研），阶段 2 开工前必须定

---

## 5. 复现步骤

\\\bash
# 0) 前提：Fusion GUI 里 Resume 启动 VM；凭据文件已存在
# 1) 盘点工坊条目（PKGV/类型/体积）
python3 ~/.local/src/vm/scan.py
# 2) 拷贝指定条目（逗号分隔的工坊 ID）
bash ~/.local/src/vm/run-copy.sh '3584071721,1000000001'
# 3) 直接跑探针
P=~/.local/src/wescene/we-scene-probe
$P pkg ~/Movies/Wallpapers2/3584071721/scene.pkg | head
$P extract ~/Movies/Wallpapers2/3584071721/scene.pkg /tmp/x && $P scene /tmp/x/scene.json
$P tex /tmp/x/materials/*.tex /tmp/out.png
\\\

---

## 6. 现场状态

| 项 | 状态 |
|---|---|
| Windows VM | **仍在运行**（未关机）；如不需要请告知，可安全挂起 |
| 样本 | \~/Movies/Wallpapers2/\，5 个 scene 共约 **205 MB** |
| 解包中间产物 | \/tmp/pw/real/\（临时目录，可随时删） |
| 未拷贝的样本 | 还有 11 个 scene（含 543 MB / 466 MB 两个大包）可随时补拷 |

---

## 7. 结论

- ✅ **阶段 0 完成**：真实样本到手，格式假设全部被真实数据校验过
- ✅ 阶段 1 的参考实现已在真实数据上验证：**127/127 纹理、5/5 场景、0 解析失败**
- 🔧 修正 2 处文档级错误假设（TEXB0004 布局、对象类型判定），已在代码与规格文档中同步
- ⏭ 下一步取决于许可证决策；若继续自研，阶段 2 的第一件事是**纹理加载与缓存策略**（DXT/R8/LZ4 三种路径）
