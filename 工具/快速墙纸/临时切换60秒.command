#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ ! -x dist/WallpaperQuickSwitch/space-inventory ]]; then
  bash 工具/快速墙纸/build.sh
fi
image="${1:-$PWD/dist/SpaceTransitionDiagnostics/scene-transition.heic}"
python3 工具/快速墙纸/wallpaper-switch.py timed "$image" --spaces 1,2 --display 1
