#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/Backend.swift Tests/LiveControls.swift -o .build/checks/live-controls
.build/checks/live-controls
