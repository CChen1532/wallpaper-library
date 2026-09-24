#!/bin/bash
# Build the pinned Mirage v1.1.4 SceneRenderer with the local arm64 toolchain.
# No shell profile, upstream source, runtime bundle, or desktop wallpaper is changed.
set -euo pipefail

mode="${1:---build}"
if [[ "$#" -gt 1 || ( "$mode" != "--build" && "$mode" != "--check" ) ]]; then
    printf 'Usage: %s [--check|--build]\n' "$0" >&2
    exit 2
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mirage_root="$project_root/ThirdParty/MirageWallpaper"
scene_root="$mirage_root/SceneRenderer"
brew_root="${HOMEBREW_PREFIX:-$HOME/homebrew}"
llvm_root="${LLVM_PREFIX:-$HOME/tools/llvm}"
jobs="${JOBS:-8}"
expected_revision='d639939b925f08cfa0e5227ed9bea79529348fd6'
build_root="$scene_root/build/macos-arm64-clang-release"
ffmpeg_root="$mirage_root/Mirage/build/ffmpeg/arm64"

die() { printf 'Mirage source build: %s\n' "$*" >&2; exit 2; }

[[ "$(uname -m)" == 'arm64' ]] || die 'this local build script supports arm64 only'
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer'
[[ -d "$scene_root" ]] || die 'Mirage submodule is missing; run git submodule update --init'
[[ "$(git -C "$mirage_root" rev-parse HEAD)" == "$expected_revision" ]] ||
    die 'Mirage submodule is not at the pinned v1.1.4 revision'

for tool_path in "$brew_root/bin/brew" "$brew_root/bin/cmake" "$brew_root/bin/ninja" \
                 "$brew_root/bin/pkg-config" "$brew_root/bin/glslangValidator" \
                 "$llvm_root/bin/clang" "$llvm_root/bin/clang++"; do
    [[ -x "$tool_path" ]] || die "missing executable: $tool_path"
done
[[ "$("$brew_root/bin/brew" --prefix)" == "$brew_root" ]] || die 'Homebrew prefix does not match HOMEBREW_PREFIX'
"$llvm_root/bin/clang++" --version | grep -q 'clang version 22\.' || die 'LLVM Clang 22 is required'

for formula in vulkan-loader vulkan-headers glslang glfw freetype fontconfig lz4 dav1d molten-vk; do
    [[ -e "$brew_root/opt/$formula" ]] || die "missing Homebrew formula: $formula"
done
[[ -f "$brew_root/etc/vulkan/icd.d/MoltenVK_icd.json" ]] || die 'MoltenVK ICD is missing'

sdk="$(xcrun --sdk macosx --show-sdk-path)"
sdk_cxx_headers="$sdk/usr/include/c++/v1"
[[ -d "$sdk_cxx_headers" ]] || die 'SDK libc++ headers are missing'
stdlib_flags="-nostdinc++ -isystem $sdk_cxx_headers"

printf 'Mirage source: %s\n' "$expected_revision"
printf 'Toolchain: %s / %s\n' "$brew_root" "$llvm_root"
printf 'SDK libc++: %s\n' "$sdk_cxx_headers"
if [[ "$mode" == '--check' ]]; then
    if [[ -x "$build_root/Tools/SceneWallpaper/SceneWallpaper" ]]; then
        printf 'Existing source-built renderer: %s\n' "$build_root/Tools/SceneWallpaper/SceneWallpaper"
    else
        printf 'Source-built renderer: absent; run --build\n'
    fi
    exit 0
fi

export PATH="$brew_root/bin:$llvm_root/bin:$PATH"
export PKG_CONFIG_PATH="$brew_root/lib/pkgconfig:$brew_root/share/pkgconfig:$brew_root/opt/freetype/lib/pkgconfig:$brew_root/opt/glfw/lib/pkgconfig:$brew_root/opt/vulkan-loader/lib/pkgconfig:$brew_root/opt/fontconfig/lib/pkgconfig:$brew_root/opt/lz4/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Upstream pins and verifies its decoder-only FFmpeg source. On a matching
# existing build this step exits without rebuilding it.
bash "$mirage_root/scripts/build_ffmpeg.sh" arm64
[[ -f "$ffmpeg_root/lib/pkgconfig/libavcodec.pc" ]] || die 'bundled FFmpeg build is missing'
export PKG_CONFIG_PATH="$ffmpeg_root/lib/pkgconfig:$PKG_CONFIG_PATH"

cd "$scene_root"
"$brew_root/bin/cmake" --preset macos-arm64-clang-release \
    -DCMAKE_C_COMPILER="$llvm_root/bin/clang" \
    -DCMAKE_CXX_COMPILER="$llvm_root/bin/clang++" \
    -DCMAKE_OBJCXX_COMPILER="$llvm_root/bin/clang++" \
    -DCMAKE_CXX_FLAGS="$stdlib_flags" \
    -DCMAKE_OBJCXX_FLAGS="$stdlib_flags" \
    -DCMAKE_PREFIX_PATH="$brew_root;$brew_root/opt/molten-vk;$brew_root/opt/vulkan-loader;$brew_root/opt/vulkan-headers;$brew_root/opt/glfw;$brew_root/opt/freetype;$brew_root/opt/fontconfig;$brew_root/opt/lz4"
"$brew_root/bin/cmake" --build "$build_root" --parallel "$jobs"

scene_wallpaper="$build_root/Tools/SceneWallpaper/SceneWallpaper"
scene_viewer="$build_root/Tools/SceneViewer/SceneViewer"
scene_saver="$build_root/Tools/SceneScreenSaver/libMirageSceneSaver.dylib"
[[ -x "$scene_wallpaper" && -x "$scene_viewer" && -f "$scene_saver" ]] || die 'one or more Scene build artifacts are missing'
help_text="$("$scene_wallpaper" --help 2>&1)"
for option in '--display-id' '--control-stdin' '--deferred-show' '--run-seconds'; do
    [[ "$help_text" == *"$option"* ]] || die "source-built renderer lacks $option"
done
printf 'Built from source (not launched on desktop):\n  %s\n  %s\n  %s\n' "$scene_wallpaper" "$scene_viewer" "$scene_saver"
