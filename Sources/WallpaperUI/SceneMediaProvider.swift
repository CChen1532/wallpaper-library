import Foundation
import CryptoKit
import ImageIO

/// Optional local-only media integration. The pinned helper reads macOS media
/// metadata; no artwork URLs are downloaded and no data leaves this machine.
actor SceneMediaProvider {
    nonisolated static let empty = Data(#"{"state":0,"title":"","artist":"","album":"","albumArtist":"","position":0,"duration":0,"artURL":"","previousArtURL":""}"#.utf8)
    private var lastArtwork = ""
    private var lastIdentity = ""
    private let runner: any CommandExecuting
    private let directory: URL
    init(runner: any CommandExecuting = CommandRunner(), directory: URL? = nil) {
        self.runner = runner
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperUI/MediaArtwork", isDirectory: true)
    }
    func read() async -> (data: Data, status: String) {
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("NowPlaying/libWallpaperNowPlaying.dylib"),
              FileManager.default.isReadableFile(atPath: helper.path) else { return (Self.empty, "媒体信息组件不可用") }
        do {
            let result = try await runner.run("/usr/bin/perl", ["-MDynaLoader", "-e",
                "$h=DynaLoader::dl_load_file($ARGV[0],0) or exit 2;"
                + "$s=DynaLoader::dl_find_symbol($h,'MiragePrintNowPlayingJSON') or exit 3;"
                + "$f=DynaLoader::dl_install_xsub('main::wallpaper_now_playing',$s);wallpaper_now_playing();",
                helper.path], timeout: 4)
            guard result.code == 0 else { return (Self.empty, "系统暂不提供媒体信息") }
            guard let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any],
                  let payload = try payload(object) else { return (Self.empty, "没有可读取的媒体信息") }
            return (payload, "媒体信息已连接")
        } catch is CancellationError { return (Self.empty, "媒体信息未开启") }
        catch { return (Self.empty, "没有可读取的媒体信息") }
    }

    func payload(_ object: [String: Any]) throws -> Data? {
        let title = String((object["title"] as? String ?? "").prefix(512))
        guard !title.isEmpty else { lastIdentity = ""; lastArtwork = ""; return nil }
        func text(_ key: String) -> String { String((object[key] as? String ?? "").prefix(512)) }
        func number(_ key: String) -> Double {
            guard let value = object[key] as? Double, value.isFinite else { return 0 }
            return max(0, min(value, 1_000_000_000))
        }
        let identity = [title, text("artist"), text("album")].joined(separator: "\u{1f}")
        let previous = lastArtwork
        if identity != lastIdentity { lastArtwork = ""; lastIdentity = identity }
        if let encoded = object["artworkData"] as? String, encoded.utf8.count <= 800_000,
           let bytes = Data(base64Encoded: encoded),
           let source = CGImageSourceCreateWithData(bytes as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
           ] as CFDictionary) {
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent(digest + ".png")
            if file.path != lastArtwork {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = NSMutableData()
                if let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(output, image, nil)
                    if CGImageDestinationFinalize(output) { try (data as Data).write(to: file, options: .atomic); lastArtwork = file.path }
                }
                // Bound the cache; retain both transition images.
                let retainedNames = Set([lastArtwork, previous].filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).lastPathComponent })
                for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                    where !retainedNames.contains(old.lastPathComponent) {
                    try? FileManager.default.removeItem(at: old)
                }
            }
        }
        let duration = number("duration")
        let position = duration > 0 ? min(duration, number("position")) : number("position")
        return try JSONSerialization.data(withJSONObject: [
            "state": (object["playing"] as? Bool ?? false) ? 1 : 2,
            "title": title, "artist": text("artist"), "album": text("album"), "albumArtist": text("albumArtist"),
            "position": position, "duration": duration,
            "artURL": lastArtwork, "previousArtURL": previous
        ], options: [.sortedKeys])
    }
}
