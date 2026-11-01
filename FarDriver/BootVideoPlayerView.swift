//
//  BootVideoPlayerView.swift
//  开机动画全屏播放：视频播完自动回调，然后进入竞技仪表
//

import SwiftUI
import AVKit

struct BootVideoPlayerView: View {

    /// 播完或出错时调用
    let onFinished: () -> Void

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoLayerView(player: player)
                    .ignoresSafeArea()
                    // 视频按比例铺满，不露黑边
                    .aspectRatio(contentMode: .fill)
            }
        }
        .onAppear { setup() }
        .onDisappear { cleanup() }
    }

    private func setup() {
        guard let url = BootVideo.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            onFinished()
            return
        }

        // 静音播放，避免和自检音效冲突
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .pause

        // 播完的通知
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onFinished()
        }

        // 音量设为 0
        p.volume = 0
        player = p
        p.play()
    }

    private func cleanup() {
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        player?.pause()
        player = nil
    }
}

/// 把 AVPlayerLayer 包成 SwiftUI 视图
private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}
