#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/Backend.swift Sources/WallpaperUI/LibraryModel.swift Sources/WallpaperUI/SceneLimitationLabels.swift Tests/BackendChecks.swift -o .build/checks/backend-checks
.build/checks/backend-checks "$@"
