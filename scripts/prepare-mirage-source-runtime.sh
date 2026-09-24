#!/bin/bash
# Prepare an ignored, local-only runtime for the pinned source-built SceneWallpaper.
# Its executable retains absolute Homebrew and FFmpeg dependencies; do not ship it.
set -euo pipefail
cd "$(dirname "$0")/.."

mirage_root="$PWD/ThirdParty/MirageWallpaper"
source_renderer="$mirage_root/SceneRenderer/build/macos-arm64-clang-release/Tools/SceneWallpaper/SceneWallpaper"
brew_root="${HOMEBREW_PREFIX:-$HOME/homebrew}"
brew_icd="$brew_root/etc/vulkan/icd.d/MoltenVK_icd.json"
brew_moltenvk="$brew_root/lib/libMoltenVK.dylib"
brew_vulkan_loader="$brew_root/opt/vulkan-loader/lib/libvulkan.1.dylib"
target='dist/MirageSourceRuntime'

[[ "$(git -C "$mirage_root" rev-parse HEAD)" == 'd639939b925f08cfa0e5227ed9bea79529348fd6' ]] || {
    printf 'Mirage submodule is not at pinned v1.1.4\n' >&2; exit 2;
}
[[ -x "$source_renderer" && -d "$mirage_root/assets" && -f "$brew_icd" && -f "$brew_moltenvk" && -f "$brew_vulkan_loader" ]] || {
    printf 'Source renderer, assets, Vulkan Loader, or MoltenVK is missing\n' >&2; exit 2;
}
[[ ! -e "$target" && ! -L "$target" ]] || { printf 'Runtime already exists: %s\n' "$target" >&2; exit 2; }

mkdir -p dist
temporary="$(mktemp -d 'dist/.mirage-source.XXXXXX')"
trap 'rm -rf "$temporary"' EXIT
resources="$temporary/Contents/Resources"
mkdir -p "$resources/Renderers/vulkan/icd.d" "$resources/lib" "$temporary/Contents/Frameworks"
install -m 755 "$source_renderer" "$resources/Renderers/SceneWallpaper"
cp "$brew_icd" "$resources/Renderers/vulkan/icd.d/MoltenVK_icd.json"
ln -s "$brew_moltenvk" "$resources/lib/libMoltenVK.dylib"
ln -s "$brew_vulkan_loader" "$temporary/Contents/Frameworks/libvulkan.1.dylib"
ln -s "$mirage_root/assets" "$resources/assets"
mv "$temporary" "$target"
printf 'Prepared local source runtime (not launched): %s/%s\n' "$PWD" "$target"
