#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library -module-cache-path .build/checks/module-cache \
  Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/WorkshopURLParser.swift \
  Sources/WallpaperUI/WorkshopCore.swift Sources/WallpaperUI/WorkshopSteam.swift \
  Sources/WallpaperUI/MaterialDiscovery.swift Sources/WallpaperUI/Backend.swift \
  Tests/WorkshopChecks.swift -o .build/checks/workshop-checks
.build/checks/workshop-checks "$@"
