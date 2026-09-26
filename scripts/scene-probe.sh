#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/wescene-probe.XXXXXX")"
swiftc -parse-as-library -O "$project_dir/Sources/GravitySceneCore/"*.swift "$project_dir/Sources/WESceneCore/"*.swift "$project_dir/工具/we-scene-probe/"*.swift -o "$build_dir/we-scene-probe"
exec "$build_dir/we-scene-probe" "$@"
