// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WallpaperUI", platforms: [.macOS(.v14)], products: [
    .executable(name: "MoonSceneRenderer", targets: ["MoonSceneRenderer"]),
    .executable(name: "GravitySceneRenderer", targets: ["GravitySceneRenderer"]),
    .executable(name: "WallpaperUI", targets: ["WallpaperUI"]),
    .executable(name: "WESceneVisibleProbe", targets: ["WESceneVisibleProbe"]),
    .executable(name: "WESceneDesktopProbe", targets: ["WESceneDesktopProbe"]),
    .executable(name: "MirageSceneBridgeProbe", targets: ["MirageSceneBridgeProbe"])
], targets: [
    .executableTarget(name: "WallpaperUI", dependencies: ["WESceneCore", "MirageSceneBridge", "GravitySceneCore"]),
    .executableTarget(name: "WESceneVisibleProbe", dependencies: ["WESceneCore"]),
    .executableTarget(name: "WESceneDesktopProbe", dependencies: ["WESceneCore"]),
    .target(name: "WESceneCore", dependencies: ["GravitySceneCore"]),
    .target(name: "GravitySceneCore"),
    .executableTarget(name: "MoonSceneRenderer", resources: [.copy("Web")]),
    .executableTarget(name: "GravitySceneRenderer", dependencies: ["GravitySceneCore"], resources: [.copy("Gravity.metal")]),
    .target(name: "MirageSceneBridge"),
    .executableTarget(name: "MirageSceneBridgeProbe", dependencies: ["MirageSceneBridge"])
])
