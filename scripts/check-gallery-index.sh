#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -O -module-cache-path .build/checks/module-cache -parse-as-library Sources/WallpaperUI/GalleryIndex.swift Tests/GalleryIndexChecks.swift -o .build/checks/gallery-index-checks
.build/checks/gallery-index-checks
