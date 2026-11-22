//
//  DynamicBackgroundView.swift
//  竞技仪表的背景：纯色 / 图片 / 视频 / 粒子动画
//
//  粒子全部用 Canvas 绘制，不依赖素材文件，
//  所以在任何机型上都能跑满 60fps。
//

import SwiftUI
import AVFoundation

// MARK: - 背景容器

struct DashBackground: View {

    let theme: DashTheme

    var body: some View {
        ZStack {
            theme.bgColor

            switch theme.backgroundKind {
            case .solid:
                EmptyView()

            case .photo:
                if let url = DashThemeStore.mediaURL(theme.photoName),
                   let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: CGFloat(theme.mediaBlur))
                        // 模糊会让边缘发虚露出底色，稍微放大盖住
                        .scaleEffect(theme.mediaBlur > 0.5 ? 1.06 : 1.0)
                        .clipped()
                        .overlay(Color.black.opacity(theme.mediaDim))
                }

            case .video:
                if let url = DashThemeStore.mediaURL(theme.videoName) {
                    LoopingVideoBackground(url: url,
                                           muted: theme.videoMuted,
                                           blur: theme.mediaBlur,
                                           dim: theme.mediaDim)
                        // 模糊：对整层视频做视觉模糊
                        .blur(radius: CGFloat(theme.mediaBlur))
                        // 稍微放大一点，避免模糊后边缘发虚露出底色
                        .scaleEffect(theme.mediaBlur > 0.5 ? 1.06 : 1.0)
                        .clipped()
                        // 暗度：盖一层黑
                        .overlay(Color.black.opacity(theme.mediaDim))
                }

            case .particles:
                ParticleBackground(style: theme.particleStyle,
                                   intensity: theme.particleIntensity,
                                   speed: theme.particleSpeed,
                                   tint: theme.accentColor)
                    // 粒子背景也用 mediaDim 控制压暗程度，最少留 20% 保证文字可读
                    .overlay(Color.black.opacity(max(0.2, theme.mediaDim)))
                    // 模糊对粒子同样有效，做一点柔化
                    .blur(radius: CGFloat(theme.mediaBlur) * 0.5)
                    .clipped()
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 循环播放的视频背景

/// 视频背景 + 模糊 + 暗度
///
/// 模糊和暗度在外层用 SwiftUI 修饰符做（对图层做视觉处理），
/// 而不是去改 AVPlayerLayer，这样调整参数时能实时生效。
private struct LoopingVideoBackground: UIViewRepresentable {

    let url: URL
    let muted: Bool
    let blur: Double
    let dim: Double

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.setup(url: url, muted: muted)
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.player?.isMuted = muted
    }

    final class PlayerLayerView: UIView {

        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func setup(url: URL, muted: Bool) {
            backgroundColor = .black
            let item = AVPlayerItem(url: url)
            let p = AVQueuePlayer()
            p.isMuted = muted
            p.actionAtItemEnd = .none
            looper = AVPlayerLooper(player: p, templateItem: item)
            playerLayer.player = p
            playerLayer.videoGravity = .resizeAspectFill
            p.play()
            player = p

            // 背景视频不能抢音频会话，否则会影响自检音效
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        }

        override func removeFromSuperview() {
            player?.pause()
            player = nil
            looper = nil
            super.removeFromSuperview()
        }
    }
}

// MARK: - 粒子背景

private struct ParticleBackground: View {

    let style: DashTheme.ParticleStyle
    let intensity: Double
    let speed: Double
    let tint: Color

    @State private var start = Date()

    var body: some View {
        // 用 TimelineView 拿到每帧时间，计算粒子位置
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start) * speed
            Canvas { gc, size in
                switch style {
                case .starfield: drawStarfield(gc, size, t)
                case .rain:      drawRain(gc, size, t)
                case .grid:      drawGrid(gc, size, t)
                case .bokeh:     drawBokeh(gc, size, t)
                }
            }
        }
        .onAppear { start = Date() }
    }

    /// 粒子数量：按屏幕面积和强度算
    private func count(_ size: CGSize, base: Double) -> Int {
        let area = Double(size.width * size.height)
        let n = base * (area / 200_000) * intensity
        return max(6, min(Int(n), 220))
    }

    // 星流：从中心向外飞散
    private func drawStarfield(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let cx = size.width / 2
        let cy = size.height / 2
        let n = count(size, base: 90)
        for i in 0..<n {
            // 用索引做伪随机，保证每颗星固定
            let seed = Double(i) * 12.9898
            let angle = (seed * 43758.5453).truncatingRemainder(dividingBy: 1) * .pi * 2
            let speedJitter = 0.4 + ((seed * 1237.7).truncatingRemainder(dividingBy: 1)) * 1.2
            let phase = (t * speedJitter * 0.35 + seed).truncatingRemainder(dividingBy: 1)
            let maxR = hypot(size.width, size.height) * 0.62
            let r = phase * maxR
            let x = cx + cos(angle) * r
            let y = cy + sin(angle) * r
            let alpha = (1 - phase) * 0.8
            let dot = CGFloat(1.0 + (1 - phase) * 1.8)
            let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
            gc.fill(Path(ellipseIn: rect),
                    with: .color(.white.opacity(alpha)))
        }
    }

    // 雨丝
    private func drawRain(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let n = count(size, base: 70)
        for i in 0..<n {
            let seed = Double(i) * 7.13
            let xBase = (seed * 9187.3).truncatingRemainder(dividingBy: 1) * Double(size.width)
            let speedJitter = 0.6 + (seed * 331.7).truncatingRemainder(dividingBy: 1) * 0.9
            let yProgress = (t * speedJitter * 0.9 + seed).truncatingRemainder(dividingBy: 1)
            let y = yProgress * Double(size.height + 60) - 30
            let len = 14.0 + (seed * 517.3).truncatingRemainder(dividingBy: 1) * 22
            var p = Path()
            p.move(to: CGPoint(x: xBase, y: y))
            p.addLine(to: CGPoint(x: xBase - len * 0.25, y: y + len))
            gc.stroke(p, with: .color(tint.opacity(0.35)),
                      style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    // 透视网格（赛博感）：水平线向下滚，竖线向消失点收
    private func drawGrid(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width
        let h = size.height
        let vanishY = h * 0.45

        // 竖线：从消失点放射
        let cols = 20
        for i in 0...cols {
            let xBottom = Double(i) / Double(cols) * Double(w)
            var p = Path()
            p.move(to: CGPoint(x: Double(w) / 2, y: vanishY))
            p.addLine(to: CGPoint(x: xBottom, y: h))
            gc.stroke(p, with: .color(tint.opacity(0.13)),
                      style: StrokeStyle(lineWidth: 1))
        }

        // 横线：从消失点往下来回滚，越近间距越大
        let rows = 12
        let scroll = t.truncatingRemainder(dividingBy: 1)
        for i in 0..<rows {
            let f = (Double(i) + scroll) / Double(rows)
            // 平方让靠近底部的线更稀疏
            let y = vanishY + (h - vanishY) * (f * f)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: w, y: y))
            let alpha = 0.08 + f * 0.22
            gc.stroke(p, with: .color(tint.opacity(alpha)),
                      style: StrokeStyle(lineWidth: 1))
        }
    }

    // 光斑飘动
    private func drawBokeh(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let n = count(size, base: 22)
        for i in 0..<n {
            let seed = Double(i) * 3.77
            let phaseX = (t * 0.06 + seed).truncatingRemainder(dividingBy: 1)
            let phaseY = (t * 0.04 + seed * 1.7).truncatingRemainder(dividingBy: 1)
            let x = phaseX * Double(size.width)
            let y = phaseY * Double(size.height)
            let r = 18.0 + (seed * 271.3).truncatingRemainder(dividingBy: 1) * 46
            let alpha = 0.05 + (seed * 91.7).truncatingRemainder(dividingBy: 1) * 0.10
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: rect), with: .color(tint.opacity(alpha)))
        }
    }
}
