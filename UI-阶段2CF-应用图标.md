# 阶段2CF：壁纸应用图标

2026-09-26，0.2.30构建1，基线9494828，预览标签v0.2.30-app-icon-preview.1。

## 设计与接入

浅色圆角底托配两张叠放的壁纸画面，采用蓝、青、淡紫和抽象景观；无文字和播放角标。沿用现有浅色原生UI和蓝色重点色。内置image_gen生成透明PNG，对两次边缘优化备选进行比较后，选用层次较柔和的初始版本；源图通过sips规范为1024平方。只作尺寸和格式转换，保留生成的alpha。

- Resources/AppIcon.png：项目中保存的1024px源图。
- Resources/AppIcon.icns：16、32、128、256、512点的1x/2x图标。
- scripts/build-icon.sh：使用系统sips与iconutil从PNG重建ICNS。
- Info.plist登记CFBundleIconFile=AppIcon；build-app.sh在签名前生成应用包内的图标。
- 菜单栏保持原来的单色desktopcomputer符号。

参考[Apple图标声明文档](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html)和只读检索到的[macOS图标项目](https://github.com/lgarron/folderify)，没有执行网站命令或增加依赖。使用imagegen与design-macos-interfaces技能；DeepSeek收到的仅为脱敏设计摘要，建议重点核验小尺寸层次和留白，主代理独立缩小检查后采用。

## 验证

- ICNS反解10个PNG，尺寸16-1024px符合各自文件名，全部保留alpha。
- 查看16、32、64、128px效果，蓝色前景在小尺寸可辨；大尺寸源图仍保留生成图的柔和材质。
- plist验证、脚本语法、Release、完整打包签名、9项输入策略检查通过；应用包内图标与项目ICNS比对。
- 未重启正在运行的应用或Dock，不将打包通过等同于系统缓存已经刷新；应用退出重开后使用新包内图标。
- 这次是视觉资源与打包改动，没有重复运行播放及素材扫描全套回归。Git哈希见最新日志。

## 最终选用图形的完整提示词

使用内置image_gen工具，transparent_background=true，无输入参考图，没有使用CLI/API回退。

Use case: logo-brand. Create ONE finished production macOS application icon for a native wallpaper library app, square 1024x1024. Actual transparent exterior. Main silhouette: a front-facing pearl-white rounded square macOS-style tile, centered, about 850x850 pixels with generous transparent 80px margins and a very subtle tight soft shadow, smooth continuous corners. In its center, a restrained stack of TWO rounded rectangular wallpaper prints: the back print peeks above and right, tinted pale periwinkle; the foreground print is upright and wide, large enough to read in a Dock icon, showing an abstract landscape of only three broad fluid layered hills, cyan and rich system-blue foreground, pale blue/lavender sky. Layers suggest wallpaper variety and gentle motion. Composition meticulously balanced with ample pale breathing room inside the tile, crisp confident silhouette, softly luminous colors, tiny realistic edge depth without glossy chrome or heavy 3D bevel. Premium understated contemporary macOS utility aesthetic matching a clean light neutral SwiftUI interface with blue accents. Legible at 32px and 64px. Artwork only, no text, no letters, no watermark, no play triangle, no monitor stand, no gears, no extra badges, no presentation board, no backdrop color, no surrounding objects. This is the complete app icon asset itself, not an app screenshot or a mockup. Use true alpha transparency outside tile and shadow.
