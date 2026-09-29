#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library Sources/WallpaperUI/CoverImageLoader.swift Sources/WallpaperUI/CoverRasterView.swift Tests/CoverPlaybackChecks.swift -o .build/checks/cover-playback-checks
.build/checks/cover-playback-checks
