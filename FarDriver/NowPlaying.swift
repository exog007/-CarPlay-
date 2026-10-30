//
//  NowPlaying.swift
//  读取系统正在播放的媒体信息（歌名 / 歌手 / 进度 / 专辑图）
//
//  原理：MPNowPlayingInfoCenter 会汇总全系统正在播放的媒体，
//  网易云、QQ 音乐、Apple Music 后台播放时都能读到，不需要登录或 API key。
//
//  ⚠️ 限制：
//    · 只能读，不能控制播放/暂停（那需要额外权限）
//    · 需要 App 的音频会话是 .playback 之外的类别，不能抢占系统
//    · 有些 App 可能不写 nowPlayingInfo，这时读不到
//

import Foundation
import MediaPlayer
import Combine

/// 系统音频中断通知（播放器状态变化时会发）
private let audioStateChanged = Notification.Name("AVAudioSessionInterruptionNotification")

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

    /// 有没有拿到可显示的信息
    var hasInfo: Bool { !title.isEmpty }

    /// 进度 0~1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    /// 进度文字 "1:23"
    var elapsedText: String { Self.mmss(elapsed) }
    var durationText: String { Self.mmss(duration) }

    private static func mmss(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var timer: Timer?
    /// 上次刷新时间，用来把进度往前推
    private var lastRefresh: Date?

    private init() {
        startMonitoring()
    }

    // MARK: - 监听

    private func startMonitoring() {
        // 每次系统媒体信息变化都会发这个通知
        NotificationCenter.default.addObserver(
            forName: .MPNowPlayingInfoCenterDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        // 播放/暂停状态变化
        NotificationCenter.default.addObserver(
            forName: audioStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        refresh()

        // 每秒刷一次，让进度条和数字走动
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 从系统读一次当前媒体信息
    func refresh() {
        let center = MPNowPlayingInfoCenter.default()
        guard let info = center.nowPlayingInfo else {
            // 没有信息就清空
            if !title.isEmpty {
                title = ""
                artist = ""
                elapsed = 0
                duration = 0
                artwork = nil
            }
            isPlaying = false
            return
        }

        title = info[MPMediaItemPropertyTitle] as? String ?? ""
        artist = info[MPMediaItemPropertyArtist] as? String ?? ""

        let d = info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
        let e = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        duration = d.isFinite ? max(0, d) : 0
        elapsed = e.isFinite ? max(0, e) : 0

        // 播放速率 > 0 表示在播
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
        isPlaying = rate > 0.01

        // 封面
        if let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            artwork = art.image(at: CGSize(width: 120, height: 120))
        }

        lastRefresh = Date()
    }

    /// 每秒把进度往前推
    private func tick() {
        guard isPlaying, duration > 0 else {
            // 没在播就别推了，但偶尔也重新读一次（防止状态卡住）
            if Int(Date().timeIntervalSince1970) % 5 == 0 {
                refresh()
            }
            return
        }
        if elapsed < duration {
            elapsed += 1.0
        } else {
            // 播完了重新读一次
            refresh()
        }
    }
}
