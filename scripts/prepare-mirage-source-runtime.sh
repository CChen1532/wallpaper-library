#!/bin/bash
# Prepare an ignored, local-only runtime for the pinned source-built SceneWallpaper.
# Its executable retains absolute Homebrew and FFmpeg dependencies; do not ship it.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-default}"
[[ "$#" -le 1 && ( "$mode" == 'default' || "$mode" == '--single-space' ||
                    "$mode" == '--focus-follow' || "$mode" == '--managed-transition' ||
                    "$mode" == '--desktop-layer' ) ]] || {
    printf 'Usage: %s [--single-space|--focus-follow|--managed-transition|--desktop-layer]\n' "$0" >&2; exit 2;
}
if [[ "$mode" == '--single-space' || "$mode" == '--focus-follow' ||
      "$mode" == '--managed-transition' || "$mode" == '--desktop-layer' ]]; then
    if [[ "$mode" == '--single-space' ]]; then
        mirage_root="$PWD/dist/MirageSingleSpaceSource"
        target='dist/MirageSingleSpaceRuntime'
        patch="$PWD/patches/mirage-single-space.patch"
        expected_files='SceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.mm'
    elif [[ "$mode" == '--focus-follow' ]]; then
        mirage_root="$PWD/dist/MirageFocusFollowSource"
        target='dist/MirageFocusFollowRuntime'
        patch="$PWD/patches/mirage-focus-follow.patch"
        expected_files=$'SceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.h\nSceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.mm\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.cpp\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.h\nSceneRenderer/Tools/SceneWallpaper/WallpaperApp.cpp'
    elif [[ "$mode" == '--managed-transition' ]]; then
        mirage_root="$PWD/dist/MirageSpaceTransitionSource"
        target='dist/MirageSpaceTransitionRuntime'
        patch="$PWD/patches/mirage-space-transition-managed.patch"
        expected_files=$'SceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.h\nSceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.mm\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.cpp\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.h\nSceneRenderer/Tools/SceneWallpaper/WallpaperApp.cpp'
    else
        mirage_root="$PWD/dist/MirageDesktopLayerSource"
        target='dist/MirageDesktopLayerRuntime'
        patch="$PWD/patches/mirage-desktop-layer-follow.patch"
        expected_files=$'SceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.h\nSceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.mm\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.cpp\nSceneRenderer/Tools/SceneWallpaper/ControlChannel.h\nSceneRenderer/Tools/SceneWallpaper/WallpaperApp.cpp'
    fi
    [[ -d "$mirage_root" && ! -L "$mirage_root" && -f "$patch" ]] || {
        printf 'Isolated source or patch is missing\n' >&2; exit 2;
    }
    git -C "$mirage_root" apply --reverse --check "$patch" || {
        printf 'Isolated patch is not applied\n' >&2; exit 2;
    }
    [[ "$(git -C "$mirage_root" diff --name-only)" == "$expected_files" ]] || {
        printf 'Isolated source has unexpected tracked changes\n' >&2; exit 2;
    }
else
    mirage_root="$PWD/ThirdParty/MirageWallpaper"
    target='dist/MirageSourceRuntime'
fi
source_renderer="$mirage_root/SceneRenderer/build/macos-arm64-clang-release/Tools/SceneWallpaper/SceneWallpaper"
brew_root="${HOMEBREW_PREFIX:-$HOME/homebrew}"
brew_icd="$brew_root/etc/vulkan/icd.d/MoltenVK_icd.json"
brew_moltenvk="$brew_root/lib/libMoltenVK.dylib"
brew_vulkan_loader="$brew_root/opt/vulkan-loader/lib/libvulkan.1.dylib"

[[ "$(git -C "$mirage_root" rev-parse HEAD)" == 'd639939b925f08cfa0e5227ed9bea79529348fd6' ]] || {
    printf 'Mirage submodule is not at pinned v1.1.4\n' >&2; exit 2;
}
[[ -x "$source_renderer" && -d "$mirage_root/assets" && -f "$brew_icd" && -f "$brew_moltenvk" && -f "$brew_vulkan_loader" ]] || {
    printf 'Source renderer, assets, Vulkan Loader, or MoltenVK is missing\n' >&2; exit 2;
}
if [[ "$mode" == '--single-space' || "$mode" == '--focus-follow' ||
      "$mode" == '--managed-transition' || "$mode" == '--desktop-layer' ]]; then
    while IFS= read -r changed_file; do
        [[ "$source_renderer" -nt "$mirage_root/$changed_file" ]] || {
            printf 'Renderer is older than patched source; rebuild first: %s\n' "$changed_file" >&2; exit 2;
        }
    done <<< "$expected_files"
fi
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
