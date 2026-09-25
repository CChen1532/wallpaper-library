// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WallpaperUI", platforms: [.macOS(.v14)], products: [
    .executable(name: "WallpaperUI", targets: ["WallpaperUI"]),
    .executable(name: "WESceneVisibleProbe", targets: ["WESceneVisibleProbe"]),
    .executable(name: "WESceneDesktopProbe", targets: ["WESceneDesktopProbe"]),
    .executable(name: "MirageSceneBridgeProbe", targets: ["MirageSceneBridgeProbe"])
], targets: [
    .executableTarget(name: "WallpaperUI", dependencies: ["WESceneCore", "MirageSceneBridge"]),
    .executableTarget(name: "WESceneVisibleProbe", dependencies: ["WESceneCore"]),
    .executableTarget(name: "WESceneDesktopProbe", dependencies: ["WESceneCore"]),
    .target(name: "WESceneCore"),
    .target(name: "MirageSceneBridge"),
    .executableTarget(name: "MirageSceneBridgeProbe", dependencies: ["MirageSceneBridge"])
])
