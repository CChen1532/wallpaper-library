#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library Sources/WallpaperUI/RotationDraft.swift Tests/RotationDraftChecks.swift -o .build/checks/rotation-draft-checks
.build/checks/rotation-draft-checks
