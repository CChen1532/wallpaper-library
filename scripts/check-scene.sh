#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/wescene-check.XXXXXX")"
swiftc -parse-as-library -O "$project_dir/Sources/WESceneCore/"*.swift "$project_dir/工具/we-scene-probe/"*.swift -o "$check_dir/we-scene-probe"
"$check_dir/we-scene-probe" selftest
result=0
for package in "$@"; do
    echo "Audit: $package"
    "$check_dir/we-scene-probe" audit "$package" || result=$?
done
echo "Temporary executable: $check_dir/we-scene-probe"
exit "$result"
