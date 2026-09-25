#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p dist/WallpaperQuickSwitch
xcrun swiftc -O -module-cache-path "$PWD/.build/wallpaper-switch-modules" \
  工具/快速墙纸/space-inventory.swift -o dist/WallpaperQuickSwitch/space-inventory
printf 'Built: dist/WallpaperQuickSwitch/space-inventory\n'
