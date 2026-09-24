#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox --product WESceneDesktopProbe
.build/debug/WESceneDesktopProbe --selftest
set +e
disabled_output="$(.build/debug/WESceneDesktopProbe --invalid-mode 2>&1)"
disabled_status=$?
set -e
if [ "$disabled_status" -ne 2 ] || [[ "$disabled_output" != *"不接受其他参数"* ]]; then
    printf 'Desktop probe invalid-argument check failed (exit %s): %s\n' "$disabled_status" "$disabled_output" >&2
    exit 1
fi
printf '桌面试验非法参数拒绝自检通过；未创建窗口\n'
