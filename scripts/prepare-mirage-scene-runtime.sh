#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

archive="${1:-}"
if [[ ! -f "$archive" ]]; then
    printf 'Usage: %s <Mirage v1.1.4 arm64 release zip>\n' "$0" >&2
    exit 2
fi

expected='491117e579a92fb69749dc6d4068aa6589a599e7fc041ae6943e0dc456ea07cb'
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
    printf 'Mirage runtime SHA-256 mismatch\n' >&2
    exit 2
fi

target='dist/MirageSceneRuntime.app'
if [[ -e "$target" ]]; then
    printf 'Runtime already exists: %s\n' "$target" >&2
    exit 2
fi

mkdir -p dist
temporary="$(mktemp -d 'dist/.mirage-runtime.XXXXXX')"
trap 'rm -rf "$temporary"' EXIT
ditto -x -k "$archive" "$temporary"
source_app="$temporary/Mirage.app"
if [[ ! -d "$source_app" ]]; then
    printf 'Release archive lacks Mirage.app\n' >&2
    exit 2
fi
codesign --verify "$source_app"
swift build --disable-sandbox -c release --product MirageSceneBridgeProbe
.build/release/MirageSceneBridgeProbe --verify-runtime "$source_app"
mv "$source_app" "$target"
printf 'Prepared pinned runtime (not launched): %s/%s\n' "$PWD" "$target"
