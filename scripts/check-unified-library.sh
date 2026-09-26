#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product WallpaperUI
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/module-cache -I .build/release/Modules -parse-as-library .build/release/GravitySceneCore.build/*.swift.o .build/release/WESceneCore.build/*.swift.o .build/release/MirageSceneBridge.build/*.swift.o Sources/WallpaperUI/ScenePreferences.swift Sources/WallpaperUI/SceneUserProperties.swift Sources/WallpaperUI/ScenePlayer.swift Sources/WallpaperUI/ScenePreparationCache.swift Sources/WallpaperUI/SceneBackdrop.swift Sources/WallpaperUI/SceneBackdropCapture.swift Sources/WallpaperUI/VideoBackdrop.swift Sources/WallpaperUI/SpaceWallpaperSettingsController.swift Sources/WallpaperUI/CommandRunner.swift Sources/WallpaperUI/MaterialDiscovery.swift Sources/WallpaperUI/Backend.swift Sources/WallpaperUI/LibraryModel.swift Sources/WallpaperUI/UnifiedLibrary.swift Tests/UnifiedLibraryChecks.swift -o .build/checks/unified-library-checks
.build/checks/unified-library-checks
