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

    /// 全局标记：视频正在播放时，其它地方（比如自检音效）别再抢音频会话
    static var isVideoPlaying = false

    /// 播完或出错时调用
    let onFinished: () -> Void

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    /// 缩放模式：stretch / fill / fit
    ///
    /// ⚠️ 用新 key（v2）：旧版本存的是 "fill"，换成 stretch 默认值不会生效，
    /// 会一直保持裁切模式。换 key 让老用户也拿到新的「拉伸铺满」默认值。
    @AppStorage("bootVideoFitModeV2") private var fitModeRaw: String = "stretch"
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

        // 标记「视频在播」，阻止自检音效抢音频会话
        Self.isVideoPlaying = true

        // 先配好音频会话，再创建播放器，避免第一声被系统掐掉
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback：静音键打开也能出声；不混音，确保声音不被别的音源压掉
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // 失败也继续播，最多没声音
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
            Self.isVideoPlaying = false
            onFinished()
        }

        player = p
        p.play()
    }

    private func cleanup() {
        Self.isVideoPlaying = false
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
