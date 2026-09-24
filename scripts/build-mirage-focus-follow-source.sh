#!/bin/bash
# Build an isolated, opt-in single-renderer Space/display-follow preview.
# The pinned Mirage submodule and the proven single-Space variant stay intact.
set -euo pipefail

mode="${1:---check}"
if [[ "$#" -gt 1 || ( "$mode" != '--check' && "$mode" != '--build' ) ]]; then
    printf 'Usage: %s [--check|--build]\n' "$0" >&2
    exit 2
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
upstream="$project_root/ThirdParty/MirageWallpaper"
isolated="$project_root/dist/MirageFocusFollowSource"
patch="$project_root/patches/mirage-focus-follow.patch"
revision='d639939b925f08cfa0e5227ed9bea79529348fd6'
ffmpeg_root="$upstream/Mirage/build/ffmpeg/arm64"
expected_files=$'SceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.h\nSceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.mm\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.cpp\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.h\nSceneRenderer/Tools/SceneWallpaper/WallpaperApp.cpp'

die() { printf 'Mirage focus-follow source: %s\n' "$*" >&2; exit 2; }
[[ -d "$upstream/SceneRenderer" && -f "$patch" ]] || die 'pinned source or patch is missing'
[[ "$(git -C "$upstream" rev-parse HEAD)" == "$revision" ]] || die 'upstream revision changed'
[[ ! -L "$isolated" ]] || die 'isolated source must not be a symlink'

if [[ ! -e "$isolated" ]]; then
    [[ "$mode" == '--build' ]] || die 'isolated source is absent; use --build'
    mkdir -p "$project_root/dist"
    git clone --local --no-hardlinks --single-branch --branch v1.1.4 "$upstream" "$isolated"
    git -C "$isolated" apply "$patch"
fi

[[ "$(git -C "$isolated" rev-parse HEAD)" == "$revision" ]] || die 'isolated revision changed'
git -C "$isolated" apply --reverse --check "$patch" || die 'focus-follow patch missing or changed'
[[ "$(git -C "$isolated" diff --name-only)" == "$expected_files" ]] || die 'unexpected tracked changes'
[[ -f "$ffmpeg_root/lib/pkgconfig/libavcodec.pc" ]] || die 'pinned FFmpeg build is missing'

MIRAGE_SOURCE_ROOT="$isolated" MIRAGE_FFMPEG_PREFIX="$ffmpeg_root" \
    bash "$project_root/scripts/build-scene-source.sh" "$mode"
