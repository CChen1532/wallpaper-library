#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library Sources/WallpaperUI/CoverImageLoader.swift Tests/CoverImageChecks.swift -o .build/checks/cover-checks
.build/checks/cover-checks
