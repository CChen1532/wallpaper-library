#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release --product WESceneVisibleProbe
mkdir -p dist/WESceneVisibleProbe.app/Contents/MacOS
cp .build/release/WESceneVisibleProbe dist/WESceneVisibleProbe.app/Contents/MacOS/WESceneVisibleProbe
cp Resources/VisibleProbeInfo.plist dist/WESceneVisibleProbe.app/Contents/Info.plist
codesign --force --sign - dist/WESceneVisibleProbe.app
printf 'Built: %s/dist/WESceneVisibleProbe.app\n' "$PWD"
