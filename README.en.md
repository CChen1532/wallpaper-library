**English** | [中文](README.md)

# WallpaperUI: a native macOS dynamic wallpaper library

A macOS 15+ SwiftUI app that turns videos and Wallpaper Engine scenes into one library of live desktop wallpapers.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-0.2.73%20preview-orange)

> **Status: 0.2.73 preview.** The main features work, but some capabilities have not been verified on real hardware. *Known limitations* lists what is still open.
> The repository is source-first. A prebuilt app is on the [Releases](https://github.com/CChen1532/wallpaper-library/releases) page (Apple silicon only, ad-hoc signed and not notarized, so right-click → *Open* the first time).
> Or install it with Homebrew: `brew install --cask CChen1532/tap/wallpaperui` ([homebrew-tap](https://github.com/CChen1532/homebrew-tap)).
> No wallpaper assets, scene packages or third-party runtimes are bundled in this repository.

![Gravity Journey · Ultra](Scenes/GravityJourney/01-Ultra/preview.png)

## Features

- One library: scenes and videos share a single "All Wallpapers" view, with multiple media folders, content detection, one search and sort order, and settings stored per wallpaper.
- Automatic discovery: the app scans your media folders at launch and every 60 seconds, with serial scheduling and incremental caching. Newly found items never start playing on their own.
- Scene wallpapers: a self-written `WESceneCore` parses the Wallpaper Engine scene format, and rendering goes to the Mirage Scene runtime bundled with the app. It prepares the first frame, loads in the background, keeps to a single instance, follows the display, and cleans up on stop, quit or sleep.
- Scene playback controls: each scene can set its own frame rate cap, volume and mute, 0.25x to 2x animation speed, crop mode and position, pause and resume (⌘⌥P), render scale / MetalFX / MSAA, battery and thermal power saving, pause while covered, media metadata and artwork, author-defined effects and shortcuts, plus PNG and JSON export and reset-after-backup. Changes to the wallpaper that is already playing go through the Mirage control channel and take effect without restarting the renderer.
- Playback display: each scene can follow the current display or stay pinned to one. A disconnected display falls back to an available screen, and the scene returns to it once it reconnects.
- Large scene packages: the app no longer blocks on the 128 MiB (UI) or 256 MiB (bridge) admission limits. A bounded index check replaces them and never copies the whole package.
- Video wallpapers: played through the `WallpaperBackend` protocol. Importing copies the file, duplicate names are skipped, and deleting moves the file to the Trash.
- Space transition backdrops: the app can capture a still frame from the current render and hold it through the system Space-switch animation (off by default, with a macOS version guard).
- Gravity Journey: a built-in native Metal scene, a golden silk formula disc with no interaction, in an "Ultra" (4K target) and an "Efficient" preset.
- SELENE Lunar Observatory: a second built-in scene, the original NASA lunar terrain with a local clock, fixed lighting, a 4096 shadow map, mouse rotation and zoom, and a slow idle spin.
- Animated covers: cards play the GIF, APNG or multi-frame WebP the author shipped; a single JPG or PNG stays still. Remote covers are limited to trusted Steam domains, update at most 30 times a second, and stop once they scroll off screen or "Reduce Motion" is on.
- Native interface: macOS sidebar, toolbar, inspector and semantic colours that follow the system light and dark appearance. Hover, selection and reflow transitions are short and respect "Reduce Motion". The interface is available in Simplified Chinese and English.

## Requirements

- macOS 15.0 or later
- Swift 5.9+ / Apple Command Line Tools to build (the SwiftUI part has no external package dependencies)
- A working Mirage Scene runtime (GPL-3.0, see below) to build the complete app

## Build from source

```sh
git clone https://github.com/CChen1532/wallpaper-library.git
cd wallpaper-library

# Scene renderer sources (GPL-3.0, ~700 MB); only needed for the full app
git submodule update --init ThirdParty/MirageWallpaper

# Prepare and package the app
bash scripts/build-app.sh

# Core self-checks
bash scripts/check.sh
```

Build output goes to `dist/` and intermediate caches to `.build/`; neither is committed. The app is ad-hoc signed and not notarized.

## Usage

- Click a video card and choose *Set as Dynamic Wallpaper*; the video then plays on the desktop. Previous, Random and Next are in the footer.
- Selecting a scene shows mouse interaction, click response and 30/60/120 Hz in the inspector. *Playback & Sound* holds frame rate, picture position, playback display (follow or pinned), scene sound and audio response, next to the *Quality* and *Automatic Control & Media* groups. Settings are stored per wallpaper.
- If the selected wallpaper is the one currently playing, changes offer *Apply to This Wallpaper*. Editing any other wallpaper never restarts the current scene.
- *Settings* (⌘,) manages app appearance and language; automatic rotation has its own settings page.
- *View* offers a compact (980×680) and a standard (1200×800) window; arrow keys move the selection and ⌘Return sets the selected video as the desktop wallpaper.
- *Stop* keeps rotation enabled (a scheduled task may start playback again); *Stop All* also turns rotation off.
- Thumbnail cache lives in `~/Library/Caches/WallpaperUI/Thumbnails`.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/WallpaperUI/` | SwiftUI interface, library model, backend and coordinators |
| `Sources/WESceneCore/` | Wallpaper Engine scene parsing, compositing and offline verification core |
| `Sources/MirageSceneBridge/` | Scene runtime bridge and focus-display selection |
| `Sources/GravitySceneCore/`, `Sources/GravitySceneRenderer/` | Gravity Journey scene definition and Metal renderer |
| `Sources/WESceneVisibleProbe/`, `WESceneDesktopProbe/`, `MirageSceneBridgeProbe/` | Visible-frame, desktop-level and bridge probes |
| `Tests/` | Standalone Swift assertion programs (XCTest is unavailable in a plain Command Line Tools setup) |
| `scripts/` | Build, packaging and 20+ check scripts |
| `工具/` | Scene probe, quick wallpaper switching, performance and parallax diagnostics |
| `Scenes/GravityJourney/` | Built-in native scenes (Ultra / Efficient) |
| `Resources/` | `Info.plist`, localisations and the app icon |
| `patches/` | Patches for the Mirage renderer (GPL-3.0 upstream) |

## Common checks

```sh
bash scripts/check.sh                     # core and backend boundaries
bash scripts/check-scene-playback.sh      # scene playback hand-off
bash scripts/check-unified-library.sh     # unified library and material discovery
bash scripts/check-gallery-navigation.sh  # gallery navigation and input policy
bash scripts/check-renderer-features.sh   # scene renderer features and preference migration
bash scripts/check-localization.sh        # interface localisation coverage
python3 scripts/check-scene-input.py      # scene input wiring
bash scripts/check.sh --live              # read real media (does not change playback)
```

`--live` reads real media and writes the thumbnail cache without changing playback state; `--media` creates tiny videos in a temporary folder to test import, caching, corrupt files and deletion.

## Known limitations

- Scene coverage is still incomplete. Custom images and textures, application and file shortcuts, and system media information landed in 0.2.41, but they depend on the asset binding them, and only controlled inputs and single scenes were checked. Author groups and conditional visibility are still not fully reproduced. Multiple-display hot-plugging, Space switching and long-running stability have not been verified on real hardware.
- Space switching: the system wallpaper can still flash briefly during the switch animation. The current approach covers it with a still frame (off by default). The private wallpaper structures macOS uses may change between releases.
- Performance: the 4K/120 FPS target of Gravity Journey Ultra is a goal, not a measurement; the tested machine did not reach it. Interface setting reads were optimised, which says nothing about whole-frame rendering performance.
- Video backend: the third-party `phonto` / `phonto-wall`. The repository source does not include it; the prebuilt package on Releases ships a portable copy. The author's local fix for its battery behaviour is not part of this repository. Desktop playback and in-app preview are different things; this version has no in-app player.
- Rotation: the local control script passes only the interval, not the mode, so the UI exposes random rotation only.
- Symlinks and paths outside the media folders cannot be played or deleted directly; existing media is scanned for lowercase `.mp4` only.
- No launch-at-login support.

## Third-party and licensing

- This project's own source is MIT licensed, see [LICENSE](LICENSE).
- [MirageWallpaper](https://github.com/laobamac/MirageWallpaper) (GPL-3.0) is referenced as a Git submodule, and its code is not distributed with this repository. Fetch it yourself to build the full app, at which point its GPL-3.0 terms apply. The patches in `patches/` are modifications of that upstream.
- The video backend `phonto` / `phonto-wall` is a third-party tool (GPL-3.0) and is not part of this repository's source. The prebuilt package on Releases ships a portable copy plus a CPython runtime, so a machine without a development setup can run it directly.
- Scene format work references public reverse-engineering notes and format documentation; GPL reference implementations were used as black-box comparisons only, with no code copied.
- This repository contains no wallpaper assets, Wallpaper Engine scene packages, fonts or commercial resources, and is not affiliated with Wallpaper Engine, Steam or their publishers.
- Dynamic wallpapers decode video or render scenes continuously, which costs battery and generates heat; changing desktop wallpaper settings is done at your own risk.

## Disclaimer

The software is provided as is, with no warranty, and you use it at your own risk. The full text is in [DISCLAIMER.md](DISCLAIMER.md).

- It is not affiliated with, sponsored by or endorsed by Wallpaper Engine, Steam, Valve or their publishers.
- It reads and writes macOS desktop wallpaper settings, including private structures Apple does not document. A system update or another wallpaper app can break it, so back up before you change anything.
- This repository ships no wallpaper assets, scene packages, fonts or commercial resources. Licensing of anything you import is your responsibility.
- Workshop downloads run Valve's steamcmd on your own machine with your own Steam account. The password is never stored or uploaded, and Steam's terms apply.
- Release builds are signed locally and are not notarised by Apple. Bypassing Gatekeeper is your own risk.
- Live wallpapers decode video or render scenes continuously, so expect more battery use and heat.
- Please do not paste account names, passwords or logs with personal information into issues or discussions.

## Acknowledgements

This app works because of the people and projects below.

- [MirageWallpaper](https://github.com/laobamac/MirageWallpaper): the rendering runtime for Wallpaper Engine scenes, GPL-3.0, bundled with the app. Without it, a scene wallpaper would be a pile of parsed JSON and nothing on screen.
- `phonto` / `phonto-wall`: the backend that plays video wallpapers on the desktop. The repository source does not include it; the prebuilt package ships a portable copy, and a source build needs you to provide your own.
- The open-source libraries shipped inside the app: FFmpeg, MoltenVK, the Vulkan loader, freetype, fontconfig, libpng, lz4, dav1d and gettext, plus the CPython runtime inside the prebuilt package. Licence texts for the scene runtime live in `WallpaperUI.app/Contents/Resources/SceneRuntime/Contents/Resources/Licenses/`, and those for the portable tools and Python in `WallpaperUI.app/Contents/Resources/Licenses/`.
- The Wallpaper Engine scene format, and the community that reverse-engineered it. The format details here were pieced together from public notes; corrections are welcome.
- Apple's SwiftUI, Metal, MetalFX and AVFoundation, which the interface, the renderer and media decoding are built on.

If someone is missing from this list, or a credit is wrong, open an issue and say so.

## Documentation

- [Development plan](开发计划.md): current version state, open items and verification entry points (Chinese)
- [Condensed project overview](项目精简总览.md): condensed development history and confirmed conclusions (Chinese)
- [state.example.json](state.example.json): sanitised state sample

> The 100 stage reports produced during development are not part of this repository; the author keeps them locally, so references marked "未收录" (not included) cannot be opened.

## Feedback

Issues and ideas are welcome via [Issues](https://github.com/CChen1532/wallpaper-library/issues). Please include your macOS version, the media type (video / scene) and minimal reproduction steps.
