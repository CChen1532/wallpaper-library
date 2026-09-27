#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -parse-as-library Sources/GravitySceneCore/*.swift Sources/MirageSceneBridge/*.swift Sources/WallpaperUI/SceneImageImport.swift Sources/WallpaperUI/SceneScriptStorage.swift Sources/WallpaperUI/SceneRuntimeControls.swift Sources/WallpaperUI/SceneMediaProvider.swift Sources/WallpaperUI/ScenePreferences.swift Sources/WallpaperUI/SceneUserProperties.swift Sources/WallpaperUI/ScenePlayer.swift Sources/WallpaperUI/ScenePreparationCache.swift Sources/WallpaperUI/SceneBackdrop.swift Sources/WallpaperUI/SceneBackdropCapture.swift Sources/WallpaperUI/VideoBackdrop.swift Sources/WallpaperUI/SpaceWallpaperSettingsController.swift Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/MaterialDiscovery.swift Sources/WallpaperUI/Backend.swift Sources/WallpaperUI/LibraryModel.swift Sources/WallpaperUI/SceneLimitationLabels.swift Tests/BackendChecks.swift -o .build/checks/backend-checks
.build/checks/backend-checks "$@"
