#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks/localization-checks
python3 scripts/check-localization.py
swiftc -parse-as-library Sources/WallpaperUI/AppLanguage.swift Tests/LocalizationChecks.swift \
  -o .build/checks/localization-checks/localization-checks
# AppStrings 从 Bundle.main 读取 en.lproj，独立可执行文件需要把它放在同目录
rm -rf .build/checks/localization-checks/en.lproj
cp -R Resources/en.lproj .build/checks/localization-checks/en.lproj
.build/checks/localization-checks/localization-checks
