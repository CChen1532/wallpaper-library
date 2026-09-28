# 阶段 2DJ：滑块刻度滚动卡顿修复（0.2.58 预览）

日期：2026-09-28

## 问题与根因

用户反馈 0.2.57 的太阳系等长设置详情栏实际滑动仍非常卡顿。上轮的 `LazyVStack` 只减少视图创建，并未减少可见滑块的绘制成本。对已安装 0.2.57 的“实时太阳系 Live Solar System - SYKM”详情栏连续翻页，同时用 macOS `sample` 采样 10 秒：主线程约 8112 个样本中，488 个位于 `-[NSSliderTickMarks drawRect:]`。SwiftUI `Slider(value:in:step:)` 为细步长创建大量原生刻度；每次滚动重画是本次确认的热点。

## 修改

作者属性和内置场景参数的滑块改用无可视刻度的 `Slider(value:in:)`，并在绑定写入时按原下界、步长与范围吸附数值。作者属性保存时仍经过原有 `ScenePropertyDefinition.validated` 校验。设置项、范围和保存位置不变。保留 0.2.57 的按需列表。

## 验证

- `bash scripts/build-app.sh`：Release 构建、运行时资源、签名与 9 项输入策略检查通过；已安装到 `/Applications/WallpaperUI.app`，版本读回 0.2.58。0.2.57 安装版备份于 `dist/.WallpaperUIPrevious/WallpaperUI-installed-before-0.2.58.app.backup`。
- 同一太阳系详情栏、同样 8 次辅助功能翻页：旧版单次返回耗时合计 7453 ms，新版 3029 ms。该数值包含工具调用和 AppKit 响应，不是滚动动画帧率。
- 新版 10 秒采样未再出现 `NSSliderTickMarks drawRect:`；直接滚动指令连续上／下各 4 次成功，单次工具返回约 132-363 ms。截图可见中后段开关、图片控件与滑块，没有空白。
- 作者滑块“底色不透明度 Opacity”通过辅助功能步进由 0.2 增至 0.3，再减回 0.2；最后桌面保持待机、未播放壁纸。

这证明特定主线程绘制热点已消失，且该长详情栏的操作响应明显改善；尚无逐帧 FPS 或用户触控板手感的最终结论。若仍感到卡顿，下一步应采集对应素材与实际手势期间的主线程／帧时间，而非重复仅测辅助功能翻页。
