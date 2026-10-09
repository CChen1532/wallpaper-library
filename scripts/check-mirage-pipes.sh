#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library \
  Sources/MirageSceneBridge/*.swift Tests/MiragePipeChecks.swift -o .build/checks/mirage-pipe-checks
.build/checks/mirage-pipe-checks
