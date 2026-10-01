#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library -module-cache-path .build/checks/module-cache Sources/WallpaperUI/WorkshopDownloadProgress.swift Tests/WorkshopProgressChecks.swift -o .build/checks/workshop-progress-checks
.build/checks/workshop-progress-checks "$@"
