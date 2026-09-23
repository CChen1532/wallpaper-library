#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release
mkdir -p dist/WallpaperUI.app/Contents/MacOS
cp .build/release/WallpaperUI dist/WallpaperUI.app/Contents/MacOS/WallpaperUI
cp Resources/Info.plist dist/WallpaperUI.app/Contents/Info.plist
codesign --force --sign - dist/WallpaperUI.app
printf 'Built: %s/dist/WallpaperUI.app\n' "$PWD"
