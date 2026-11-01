//
//  BootVideoPlayerView.swift
//  开机动画全屏播放：视频播完自动回调，然后进入竞技仪表
//
//  支持：
//    · 播放视频自带声音
//    · 三种缩放模式（填充 / 适应 / 拉伸）
//    · 用户微调缩放比例和画面偏移
//

import SwiftUI
import AVKit

struct BootVideoPlayerView: View {

    /// 播完或出错时调用
    let onFinished: () -> Void

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    /// 缩放模式（读取设置）
    @AppStorage("bootVideoFitMode") private var fitModeRaw: String = "fill"
    /// 额外放大倍数 0.5 ~ 2.0
    @AppStorage("bootVideoZoom") private var zoom: Double = 1.0
    /// 水平偏移 -1 ~ 1（占屏幕宽度的比例）
    @AppStorage("bootVideoOffsetX") private var offsetX: Double = 0
    /// 垂直偏移
    @AppStorage("bootVideoOffsetY") private var offsetY: Double = 0

    private var videoGravity: AVLayerVideoGravity {
        switch fitModeRaw {
        case "fit":    return .resizeAspect
        case "stretch": return .resize
        default:        return .resizeAspectFill
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let player {
                    VideoLayerView(player: player, gravity: videoGravity)
                        .ignoresSafeArea()
                        // 额外缩放 + 偏移
                        .scaleEffect(zoom)
                        .offset(x: offsetX * geo.size.width,
                                y: offsetY * geo.size.height)
                        .clipped()
                }
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

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        // 播放视频自带的声音
        p.isMuted = false
        p.volume = 1.0
        p.actionAtItemEnd = .pause

        // 播完的通知
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onFinished()
        }

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
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.videoGravity = gravity
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = gravity
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
