#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library Sources/GravitySceneCore/*.swift Sources/MirageSceneBridge/*.swift Sources/WallpaperUI/ScenePreferences.swift Sources/WallpaperUI/SceneUserProperties.swift Sources/WallpaperUI/ScenePlayer.swift Sources/WallpaperUI/ScenePreparationCache.swift Sources/WallpaperUI/SceneBackdrop.swift Sources/WallpaperUI/SceneBackdropCapture.swift Sources/WallpaperUI/VideoBackdrop.swift Sources/WallpaperUI/SpaceWallpaperSettingsController.swift Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/Backend.swift Sources/WallpaperUI/LibraryModel.swift Tests/ScenePlaybackChecks.swift -o .build/checks/scene-playback-checks
.build/checks/scene-playback-checks
