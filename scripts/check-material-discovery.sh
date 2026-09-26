#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/MaterialDiscovery.swift Sources/WallpaperUI/Backend.swift Tests/MaterialDiscoveryChecks.swift -o .build/checks/material-discovery-checks
.build/checks/material-discovery-checks
