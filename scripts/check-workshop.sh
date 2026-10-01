#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library -module-cache-path .build/checks/module-cache \
  Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/WorkshopURLParser.swift \
  Sources/WallpaperUI/WorkshopCore.swift Sources/WallpaperUI/WorkshopDownloadProgress.swift Sources/WallpaperUI/WorkshopSteam.swift Sources/WallpaperUI/WorkshopFilters.swift Sources/WallpaperUI/WorkshopBrowse.swift \
  Sources/WallpaperUI/MaterialDiscovery.swift Sources/GravitySceneCore/*.swift Sources/MirageSceneBridge/*.swift Sources/WallpaperUI/ScenePreferences.swift Sources/WallpaperUI/Backend.swift \
  Tests/WorkshopChecks.swift -o .build/checks/workshop-checks
.build/checks/workshop-checks "$@"
