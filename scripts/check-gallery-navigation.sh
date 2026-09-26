#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library Sources/WallpaperUI/GalleryNavigation.swift Tests/GalleryNavigationChecks.swift -o .build/checks/gallery-navigation-checks
.build/checks/gallery-navigation-checks
