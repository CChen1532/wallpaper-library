#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/wescene-check.XXXXXX")"
swiftc -O "$project_dir/工具/we-scene-probe/WESceneProbe.swift" -o "$check_dir/we-scene-probe"
"$check_dir/we-scene-probe" selftest
result=0
for package in "$@"; do
    echo "Audit: $package"
    "$check_dir/we-scene-probe" audit "$package" || result=$?
done
echo "Temporary executable: $check_dir/we-scene-probe"
exit "$result"
