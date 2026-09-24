#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox --product WESceneDesktopProbe
.build/debug/WESceneDesktopProbe --selftest
set +e
disabled_output="$(.build/debug/WESceneDesktopProbe 2>&1)"
disabled_status=$?
set -e
if [ "$disabled_status" -ne 2 ] || [[ "$disabled_output" != *"桌面试验默认禁用"* ]]; then
    printf 'Desktop probe default-off check failed (exit %s): %s\n' "$disabled_status" "$disabled_output" >&2
    exit 1
fi
printf '桌面试验默认关闭入口自检通过；未创建窗口\n'
