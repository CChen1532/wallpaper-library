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
cp .build/release/GravitySceneRenderer "$app/Contents/Resources/GravitySceneRenderer"
cp -R .build/release/WallpaperUI_GravitySceneRenderer.bundle "$app/Contents/Resources/"
cp -R Scenes/GravityJourney "$app/Contents/Resources/GravityScenes"
python3 scripts/verify-moon-asset.py
cp .build/release/MoonSceneRenderer "$app/Contents/Resources/MoonSceneRenderer"
cp -R .build/release/WallpaperUI_MoonSceneRenderer.bundle "$app/Contents/Resources/"
cp -R Scenes/LunarObservatory "$app/Contents/Resources/MoonScenes"
mkdir -p "$app/Contents/Resources/NowPlaying"
xcrun clang++ -dynamiclib -fobjc-arc -framework AppKit -framework Foundation \
    -mmacosx-version-min=14.0 Sources/MediaBridge/NowPlayingBridge.mm \
    -o "$app/Contents/Resources/NowPlaying/libWallpaperNowPlaying.dylib"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app/Contents/Resources/"
cp -R Resources/Licenses "$app/Contents/Resources/"
# Use the committed icon for reproducible packaging; iconutil may reject a
# regenerated iconset even when its input PNG and the existing ICNS are valid.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
python3 scripts/bundle-scene-runtime.py "$scene_runtime" "$app/Contents/Resources/SceneRuntime"
bash 工具/快速墙纸/build.sh
mkdir -p "$app/Contents/Resources/WallpaperSwitch"
cp 工具/快速墙纸/wallpaper-switch.py "$app/Contents/Resources/WallpaperSwitch/"
cp dist/WallpaperQuickSwitch/space-inventory "$app/Contents/Resources/WallpaperSwitch/"
# 固定签名身份：让 macOS 辅助功能授权在重新构建后依然有效。
# 原理：ad-hoc 签名的「指定要求」是 cdhash（二进制哈希），每次重建都会变，系统因此把新构建当成全新应用；
# 用固定证书签名后，指定要求变为 identifier + certificate root，重建不再影响已授予的权限。
# 未安装该证书的机器自动回退到 ad-hoc（保持可构建，但每次重建需重新授权）。
SIGN_ID="${WALLPAPERUI_SIGN_ID:-BA0E30F77944C311DA0454BD80AA9F3B5890505D}"
available_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "$SIGN_ID" =~ ^[[:xdigit:]]{40}$ ]]; then
    identity_present=$(grep -Fic -- "$SIGN_ID" <<< "$available_identities" || true)
else
    identity_present=$(grep -Fc -- "\"$SIGN_ID\"" <<< "$available_identities" || true)
fi
if [[ "$identity_present" -ne 1 ]]; then
    printf 'WARN: 签名身份 "%s" 不可用，回退 ad-hoc（每次重建都需要重新授予辅助功能权限）\n' "$SIGN_ID" >&2
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --identifier local.wallpaper.library.wallpaperswitch "$app/Contents/Resources/WallpaperSwitch/space-inventory"
codesign --force --sign "$SIGN_ID" --identifier local.wallpaper.library.moon "$app/Contents/Resources/MoonSceneRenderer"
codesign --force --sign "$SIGN_ID" --identifier local.wallpaper.library.gravity "$app/Contents/Resources/GravitySceneRenderer"
codesign --force --sign "$SIGN_ID" --identifier local.wallpaper.library.media "$app/Contents/Resources/NowPlaying/libWallpaperNowPlaying.dylib"
codesign --force --sign "$SIGN_ID" --identifier local.wallpaper.library "$app"
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
