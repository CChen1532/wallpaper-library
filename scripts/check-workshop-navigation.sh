#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library -module-cache-path .build/checks/module-cache \
  Sources/WallpaperUI/WorkshopURLParser.swift Sources/WallpaperUI/WorkshopCore.swift \
  Sources/WallpaperUI/WorkshopFilters.swift Sources/WallpaperUI/WorkshopBrowse.swift \
  Sources/WallpaperUI/WorkshopDownloadProgress.swift Sources/WallpaperUI/WorkshopDownloadProgressView.swift \
  Sources/WallpaperUI/AppLanguage.swift Sources/WallpaperUI/WorkshopSubscriptionBrowser.swift \
  Tests/WorkshopNavigationChecks.swift -o .build/checks/workshop-navigation-checks
.build/checks/workshop-navigation-checks
