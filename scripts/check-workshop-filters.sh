#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library -module-cache-path .build/checks/module-cache \
  Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/WorkshopURLParser.swift \
  Sources/WallpaperUI/WorkshopCore.swift Sources/WallpaperUI/WorkshopSteam.swift Sources/WallpaperUI/WorkshopFilters.swift Sources/WallpaperUI/WorkshopBrowse.swift \
  Sources/WallpaperUI/MaterialDiscovery.swift Sources/WallpaperUI/Backend.swift Sources/WallpaperUI/WorkshopModel.swift \
  Tests/WorkshopFilterChecks.swift -o .build/checks/workshop-filter-checks
.build/checks/workshop-filter-checks "$@"
