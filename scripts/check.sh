#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library Sources/WallpaperUI/Backend.swift Tests/BackendChecks.swift -o .build/checks/backend-checks
.build/checks/backend-checks "$@"
