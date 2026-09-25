# 阶段 2BA：逐 Space 系统壁纸恢复账本预览

日期：2026-09-25（Asia/Kuala_Lumpur）

## 本阶段完成

2AZ 再次确认 Scene 在 Space 切换动画中短暂露出原系统壁纸。系统壁纸覆盖是下一项隔离候选，但本阶段**只准备恢复流程，没有改动任何壁纸，也没有运行 Scene 桌面画面**。

新增 [`scripts/scene-wallpaper-recovery.py`](scripts/scene-wallpaper-recovery.py)：它只管理恢复文件，不调用系统墙纸设置接口。`create` 在 Git 忽略的 `dist/SceneWallpaperRecovery/` 建立草稿；`seal` 要求记录实际 Space 数、两个目标 Space 和有其他 Space 时的对照 Space、每个桌面的原选择／目录条目／相关开关、独立屏幕保护程序选择，以及 Mission Control、设置页和桌面的本地截图。用户明确确认几个桌面壁纸相同时，可用一张注明适用范围的共用桌面实显截图，但各桌面仍须有独立设置截图且原设置值一致。它检查图片在恢复目录内、格式、非空、路径不重复，并用 SHA-256 封存清单和图片。未封存的草稿不能 `begin`；`begin` 必须在任何系统设置点击之前写下 `recovery_pending`。恢复后逐 Space 按封存值记录人工核对和新截图；两个目标 Space、对照 Space（若有）及独立屏保未核对完就不能 `complete`。账本本身不能理解截图，也不能证明 macOS 的 Space 编号长期稳定，人工仍须将截图与 Mission Control 位置逐项核对。

已在 `dist/SceneWallpaperRecovery/2BA-20260925/` 建立草稿。初建时编号桌面数、按 Space 绑定的原设置和持久截图均未填入；`seal` 因缺桌面数退出 2，`begin` 因“恢复清单未封存”退出 2。这证明空草稿不能进入试验。

用户随后提供 668×244 的 Mission Control 局部截图，中间明确标为“桌面 2”，两侧可见相邻缩略图。原图 SHA-256 为 `79d69f641ee59c0e8198ac712eb43b4257a83d262ff6021a425540702d23c87a`，已复制到被 Git 忽略的草稿 `evidence/mission-control-desktop-2-partial.png`。它不能证明当前顶部列表的总桌面数或两侧缩略图的完整身份，故没有将它充作 `mission_control_image` 来封存。

用户接着报告当前有 **16 个编号桌面**，并提供覆盖顶部整条缩略图的 2684×190 截图。原图 SHA-256 为 `46d6151cb797fcb4c43917159fa3c3963f605014e78b244c303532972766647e`，已复制到 `evidence/mission-control.png`；`space_count` 依用户报告填 16（不把全屏应用缩略图计作编号桌面）。当时资料不全，`seal` 因“桌面 1 缺少 selected_name”退出 2。

用户随后确认一张 954×272 的墙纸设置截图属于“桌面 1”。截图显示“默认系统壁纸”、山脉预览及两个关闭的开关；SHA-256 为 `98b8d4a3fca88c4da543e2dd8e1a7038fe22ae26b50c107dbfb85458bc5c29e0`。已复制到 `evidence/desktop-1-settings.png`，并填入桌面 1 的原条目与开关。当时 `seal` 正确拒绝，提示“桌面 2 缺少 selected_name”。

用户又单独标明一张 936×282 截图属于“桌面 2”。该图同样显示“默认系统壁纸”和两个关闭的开关；SHA-256 为 `de5fd8cb49cd2872cd938ecfe6b37acf2d34c062be126e149904ea97fe79bcc5`。已复制到 `evidence/desktop-2-settings.png`，并填入桌面 2 的原条目与开关。恢复后仍须独立核对两个实际改动的 Space。

用户还提供并标明“桌面 3”的 996×318 墙纸设置截图：同为山脉和两个关闭的开关，SHA-256 `559c76f5a94ee06087538e8416e01804a46fc5a71712e00f3d9d6c14acfdc804`，已存为 `evidence/desktop-3-settings.png`，作为未参与试验的对照 Space。独立屏保的 944×248 截图显示 `OtherWallpaper`、所有空间开关开启，SHA-256 `5c13181ed135f3a5d75f1f53b63fc5ed20c1125d8cff5e19e730e9735c034f03`，已存为 `evidence/screen-saver.png`。当时 `seal` 已推进到检查实显截图，因缺桌面截图退出 2。

用户最后提供 2880×1864 的桌面实显截图，并明确表示“桌面 1、2、3 壁纸都一样，不需要复检”。该图 SHA-256 为 `4b1e2a2ee214d6d2a2f92dbc3ac2fdf5bbfc9b015e31c21d7c094fcd84f9a2f9`，已存为 `evidence/shared-desktop.png`。清单的 `shared_desktop_visual` 明确列出三个桌面和用户确认，三个独立设置记录也相同，因此无需再索取三张重复的试验前桌面截图。共用画面只用于原状态记录；未来若实际改动系统壁纸，仍要分别核对被改动桌面的恢复结果。

真实清单现已执行 `seal` 和 `verify`，状态为 **`sealed`**，清单 SHA-256 为 `577d11e8648edbe6e187bb3744b59e1c11abcdd7f73043affb2467482977de42`。`begin` 尚未运行，`recovery_pending` 尚未写入；没有改动系统壁纸，也没有运行新的 Scene 桌面试验。所有带截图的恢复资料位于 Git 忽略目录，不随源码提交。

资料齐备后的操作入口如下。`begin` 只写待恢复日志，不负责点击系统设置；`mark-restored`、`mark-sentinel`、`mark-screen-saver` 要带核对后观察到的原值和新的截图，`complete` 在缺项时会拒绝。若工具或 UI 故障，直接查看封存的 `manifest.json` 和截图进行人工恢复，并保留 `recovery_pending`，不要删除恢复目录。

```sh
python3 scripts/scene-wallpaper-recovery.py verify dist/SceneWallpaperRecovery/2BA-20260925
python3 scripts/scene-wallpaper-recovery.py guide dist/SceneWallpaperRecovery/2BA-20260925
# 只有获本次明确许可、准备执行第一处壁纸更改时才运行 begin
python3 scripts/scene-wallpaper-recovery.py begin dist/SceneWallpaperRecovery/2BA-20260925
```

只读观察系统设置时，展开“示例集合”后同名“默认系统壁纸”目录条目显示选中，可作为重选入口线索。三个设置截图分别由用户标明所属桌面，避免把系统设置窗口的自身位置误当作 Space 标识。只读 `WallpaperAgent` 索引中的历史条目数不等于 Mission Control 当前编号桌面数，不能替代用户的 16 个编号桌面报告。没有写入私有数据库。

Apple 公开的 [`NSWorkspace` 桌面图片接口](https://developer.apple.com/documentation/appkit/nsworkspace)面向屏幕图片 URL 与显示选项；[Apple 框架工程师说明](https://developer.apple.com/forums/thread/834630)当前没有公开接口为同一屏幕的所有 Space 一次设置图片。因此本工具不把通用 `DefaultDesktop.heic` 当成原动态航拍选择，也不声称能自动恢复到原动态播放进度。DeepSeek 对脱敏流程的独立审查提出了先确认 Space 身份与对照 Space、资料不全就停止、恢复后逐项核对等建议；这些建议已按本机 UI 和代码核对，不作为运行结果。

## 验证和下一步门槛

`python3 scripts/test-scene-wallpaper-recovery.py` 的四项安全路径通过：资料不全拒绝封存、封存截图被改动拒绝开始、共用画面必须由用户确认且三个墙纸设置相同、目标／对照／屏保未全部核对拒绝结案。Python 3.9 语法检查与 `git diff --check` 通过；真实清单的 `seal`／`verify` 通过。测试使用临时假图片，没有改系统设置。

下一步在实际试验前重新用 Mission Control 对准两个目标桌面与当前屏幕，核对封存资料仍对应现状。若 Space 身份或原选择不清、设置页跳到其他 Space、开关非预期，停止且不运行 `begin`。用户先前要求暂不修改系统壁纸；临时更改两个 Space 的系统壁纸并运行有界 Scene 试验，仍须取得明确的当次许可。正常计划结束仍须先恢复原底图并分别核对两个目标与桌面 3、独立屏保，再撤 Scene；提前停止或恢复失败时优先安全撤面并保留 `recovery_pending`，不能宣称 0.5 秒回切通过。
