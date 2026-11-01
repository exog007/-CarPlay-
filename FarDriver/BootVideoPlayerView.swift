//
//  BootVideoPlayerView.swift
//  开机动画全屏播放：视频播完自动回调，然后进入竞技仪表
//
//  支持：
//    · 播放视频自带声音
//    · 三种缩放模式（填充 / 适应 / 拉伸铺满）
//    · 用户微调缩放比例和画面偏移
//

import SwiftUI
import AVKit

struct BootVideoPlayerView: View {

    /// 播完或出错时调用
    let onFinished: () -> Void

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    /// 缩放模式：fill / fit / stretch
    @AppStorage("bootVideoFitMode") private var fitModeRaw: String = "stretch"
    /// 额外放大倍数 0.5 ~ 2.0
    @AppStorage("bootVideoZoom") private var zoom: Double = 1.0
    /// 水平偏移 -0.5 ~ 0.5（占屏幕宽度的比例）
    @AppStorage("bootVideoOffsetX") private var offsetX: Double = 0
    /// 垂直偏移
    @AppStorage("bootVideoOffsetY") private var offsetY: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let player {
                    // 关键：容器铺满整个 GeometryReader，
                    // 缩放和偏移都在容器上做，避免 aspectRatio 把画面缩回去。
                    VideoLayerView(
                        player: player,
                        mode: fitModeRaw,
                        containerSize: geo.size
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(zoom)
                    .offset(x: offsetX * geo.size.width,
                            y: offsetY * geo.size.height)
                    .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
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

        // 音画同步：先让音频会话就绪，避免视频有声但系统静音
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,
                                                            options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 失败也继续播，最多没声音
        }

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

/// 把 AVPlayerLayer 铺满容器
///
/// 拉伸模式直接用 CALayer 的 transform 把视频帧强行拉到容器大小，
/// 这样不管视频比例和屏幕比例差多少都能铺满，不会留黑边。
private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer
    let mode: String
    let containerSize: CGSize

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.mode = mode
        v.applyLayout(size: containerSize)
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.mode = mode
        uiView.applyLayout(size: containerSize)
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        var mode: String = "stretch"

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
            playerLayer.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyLayout(size: bounds.size)
        }

        /// 按模式调整 videoGravity
        ///
        /// stretch 模式用 resize（强制拉伸），其余用系统自带的等比方式。
        func applyLayout(size: CGSize) {
            guard size.width > 1, size.height > 1 else { return }
            switch mode {
            case "fit":
                playerLayer.videoGravity = .resizeAspect
            case "fill":
                playerLayer.videoGravity = .resizeAspectFill
            default:
                // 拉伸：强行铺满整个 layer
                playerLayer.videoGravity = .resize
            }
        }
    }
}
