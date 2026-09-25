#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release
scene_runtime="${SCENE_RUNTIME_SOURCE:-$PWD/dist/MirageFocusFollowRuntime}"
.build/release/MirageSceneBridgeProbe --verify-input-runtime "$scene_runtime"
mkdir -p dist
staging="$(mktemp -d 'dist/.wallpaper-app.XXXXXX')"
trap 'rm -rf "$staging"' EXIT
app="$staging/WallpaperUI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/WallpaperUI "$app/Contents/MacOS/WallpaperUI"
cp Resources/Info.plist "$app/Contents/Info.plist"
python3 scripts/bundle-scene-runtime.py "$scene_runtime" "$app/Contents/Resources/SceneRuntime"
bash 工具/快速墙纸/build.sh
mkdir -p "$app/Contents/Resources/WallpaperSwitch"
cp 工具/快速墙纸/wallpaper-switch.py "$app/Contents/Resources/WallpaperSwitch/"
cp dist/WallpaperQuickSwitch/space-inventory "$app/Contents/Resources/WallpaperSwitch/"
codesign --force --sign - "$app/Contents/Resources/WallpaperSwitch/space-inventory"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
.build/release/MirageSceneBridgeProbe --verify-input-runtime "$app/Contents/Resources/SceneRuntime"
python3 scripts/check-scene-input.py "$app/Contents/Resources/SceneRuntime/Contents/Resources/Renderers/SceneWallpaper"
# Keep the previous app available until the staged build has passed validation.
if [[ -e dist/WallpaperUI.app ]]; then
    mkdir -p dist/.WallpaperUIPrevious
    # Keep old bytes for rollback without registering another runnable .app
    # under the same bundle identifier in macOS Accessibility settings.
    backup="dist/.WallpaperUIPrevious/WallpaperUI-before-scene-$(date +%Y%m%d-%H%M%S).app.backup"
    mv dist/WallpaperUI.app "$backup"
fi
mv "$app" dist/WallpaperUI.app
printf 'Built: %s/dist/WallpaperUI.app\n' "$PWD"
