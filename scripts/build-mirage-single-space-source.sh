#!/bin/bash
# Build a local single-Space Mirage variant without modifying the pinned submodule.
# The isolated Git clone and its build products live under ignored dist/.
set -euo pipefail

mode="${1:---check}"
if [[ "$#" -gt 1 || ( "$mode" != "--check" && "$mode" != "--build" ) ]]; then
    printf 'Usage: %s [--check|--build]\n' "$0" >&2
    exit 2
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
upstream="$project_root/ThirdParty/MirageWallpaper"
isolated="$project_root/dist/MirageSingleSpaceSource"
patch="$project_root/patches/mirage-single-space.patch"
revision='d639939b925f08cfa0e5227ed9bea79529348fd6'
changed_file='SceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.mm'
ffmpeg_root="$upstream/Mirage/build/ffmpeg/arm64"

die() { printf 'Mirage single-Space source: %s\n' "$*" >&2; exit 2; }
[[ -d "$upstream/SceneRenderer" && -f "$patch" ]] || die 'pinned source or patch is missing'
[[ "$(git -C "$upstream" rev-parse HEAD)" == "$revision" ]] || die 'upstream revision does not match v1.1.4'
[[ ! -L "$isolated" ]] || die 'isolated source path must not be a symlink'

if [[ ! -e "$isolated" ]]; then
    [[ "$mode" == '--build' ]] || die 'isolated source is absent; use --build to create it'
    mkdir -p "$project_root/dist"
    git clone --local --no-hardlinks --single-branch --branch v1.1.4 "$upstream" "$isolated"
    git -C "$isolated" apply "$patch"
fi

[[ "$(git -C "$isolated" rev-parse HEAD)" == "$revision" ]] || die 'isolated source revision changed'
git -C "$isolated" apply --reverse --check "$patch" || die 'single-Space patch is missing or changed'
[[ "$(git -C "$isolated" diff --name-only)" == "$changed_file" ]] || die 'isolated source has unexpected tracked changes'
[[ -f "$ffmpeg_root/lib/pkgconfig/libavcodec.pc" ]] || die 'pinned FFmpeg build is missing'

MIRAGE_SOURCE_ROOT="$isolated" MIRAGE_FFMPEG_PREFIX="$ffmpeg_root" \
    bash "$project_root/scripts/build-scene-source.sh" "$mode"
