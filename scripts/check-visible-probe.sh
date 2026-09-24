#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox --product WESceneVisibleProbe
.build/debug/WESceneVisibleProbe --selftest
