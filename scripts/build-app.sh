#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release
scene_runtime="${SCENE_RUNTIME_SOURCE:-$PWD/dist/MirageFocusFollowRuntime}"
.build/release/MirageSceneBridgeProbe --verify-follow-runtime "$scene_runtime"
mkdir -p dist
staging="$(mktemp -d 'dist/.wallpaper-app.XXXXXX')"
trap 'rm -rf "$staging"' EXIT
app="$staging/WallpaperUI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/WallpaperUI "$app/Contents/MacOS/WallpaperUI"
cp Resources/Info.plist "$app/Contents/Info.plist"
python3 scripts/bundle-scene-runtime.py "$scene_runtime" "$app/Contents/Resources/SceneRuntime"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
.build/release/MirageSceneBridgeProbe --verify-follow-runtime "$app/Contents/Resources/SceneRuntime"
# Keep the previous app available until the staged build has passed validation.
if [[ -e dist/WallpaperUI.app ]]; then
    backup="dist/WallpaperUI-before-scene-$(date +%Y%m%d-%H%M%S).app"
    mv dist/WallpaperUI.app "$backup"
fi
mv "$app" dist/WallpaperUI.app
printf 'Built: %s/dist/WallpaperUI.app\n' "$PWD"
