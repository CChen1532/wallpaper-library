#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release --product WESceneDesktopProbe
mkdir -p dist/WESceneDesktopProbe.app/Contents/MacOS
cp .build/release/WESceneDesktopProbe dist/WESceneDesktopProbe.app/Contents/MacOS/WESceneDesktopProbe
cp Resources/DesktopProbeInfo.plist dist/WESceneDesktopProbe.app/Contents/Info.plist
codesign --force --sign - dist/WESceneDesktopProbe.app
printf 'Built (not launched): %s/dist/WESceneDesktopProbe.app\n' "$PWD"
