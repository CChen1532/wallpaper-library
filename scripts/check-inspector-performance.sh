#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" -eq 0 ]]; then
    echo "Usage: bash scripts/check-inspector-performance.sh /path/to/scene.pkg [...]"
    exit 2
fi
mkdir -p .build/checks
swiftc -O -module-cache-path .build/checks/module-cache -parse-as-library Sources/WallpaperUI/ScenePreferences.swift Sources/WallpaperUI/SceneUserProperties.swift 工具/性能检查/InspectorPerformance.swift -o .build/checks/inspector-performance
.build/checks/inspector-performance "$@"
