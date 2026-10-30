//
//  NowPlaying.swift
//  读取正在播放的媒体信息
//
//  ⚠️ 重要：
//  MediaRemote 的 MRMediaRemoteGetNowPlayingInfo 在 iOS 17 上调用会直接
//  SIGABRT 终止进程（系统保护），不能用。
//
//  现在只读本 App 自己的 nowPlayingInfo —— 也就是控制器的声音/提示音之类。
//  第三方 App（网易云等）的歌名系统不开放，读不到。
//

import Foundation
import MediaPlayer
import Combine

final class NowPlayingService: ObservableObject {

    static let shared = NowPlayingService()

    /// 歌名
    @Published private(set) var title: String = ""
    /// 歌手
    @Published private(set) var artist: String = ""
    /// 当前播放位置（秒）
    @Published private(set) var elapsed: Double = 0
    /// 总时长（秒）
    @Published private(set) var duration: Double = 0
    /// 是否正在播放
    @Published private(set) var isPlaying = false
    /// 封面图
    @Published private(set) var artwork: UIImage?

    /// 有没有可显示的信息
    var hasInfo: Bool { !title.isEmpty }

    /// 进度 0~1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var elapsedText: String { Self.mmss(elapsed) }
    var durationText: String { Self.mmss(duration) }

    private static func mmss(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var timer: Timer?

    private init() {
        startTimer()
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 读一次本 App 的媒体信息
    ///
    /// 只能读到本 App 自己通过 MPNowPlayingInfoCenter 设置的内容。
    /// 系统不开放第三方 App（网易云等）正在播的歌，所以大多数时候这里是空的。
    func refresh() {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              !info.isEmpty else {
            if !title.isEmpty {
                title = ""
                artist = ""
                elapsed = 0
                duration = 0
                artwork = nil
                isPlaying = false
            }
            return
        }

        title = info[MPMediaItemPropertyTitle] as? String ?? ""
        artist = info[MPMediaItemPropertyArtist] as? String ?? ""

        let d = info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
        let e = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        duration = d.isFinite ? max(0, d) : 0
        elapsed = e.isFinite ? max(0, e) : 0

        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
        isPlaying = rate > 0.01

        if let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            artwork = art.image(at: CGSize(width: 120, height: 120))
        }

        // 播放中：每秒推进度
        if isPlaying, duration > 0, elapsed < duration {
            elapsed += 1.0
        }
    }
}
