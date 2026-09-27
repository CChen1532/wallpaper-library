import AVKit
import SwiftUI

struct VideoPreviewSheet: View {
    let item: Wallpaper
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var muted = true
    @State private var scoped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("动态预览").font(.title2.weight(.semibold))
                Spacer()
                Toggle("声音", isOn: Binding(
                    get: { !muted },
                    set: { muted = !$0; player?.isMuted = muted }))
                    .toggleStyle(.checkbox)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(item.title).font(.headline).lineLimit(2)
            NativeVideoPlayer(player: player)
                .frame(minWidth: 640, minHeight: 360)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("仅在应用内预览，不改变桌面壁纸。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 470)
        .onAppear {
            scoped = item.url.startAccessingSecurityScopedResource()
            let player = AVPlayer(url: item.url)
            player.isMuted = muted
            self.player = player
            player.play()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let current = player?.currentItem,
                  let finished = note.object as? AVPlayerItem, current === finished else { return }
            player?.seek(to: .zero)
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            if scoped { item.url.stopAccessingSecurityScopedResource(); scoped = false }
        }
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
