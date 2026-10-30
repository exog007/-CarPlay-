//
//  NowPlaying.swift
//  读取系统正在播放的媒体信息（歌名 / 歌手 / 进度 / 专辑图）
//
//  ⚠️ 关键点：
//  公开的 `MPNowPlayingInfoCenter.default().nowPlayingInfo` 只能读**自己 App 设置**的信息，
//  读不到网易云、QQ 音乐等其他 App 正在播的歌。
//
//  要读全系统的媒体信息，只能用 MediaRemote 私有框架：
//    · dlsym 动态加载 MRMediaRemoteGetNowPlayingInfo
//    · 不需要任何 entitlement，sideload 的 App 可用
//    · 上架 App Store 会被拒（我们不上架，无影响）
//

import Foundation
import MediaPlayer
import ObjectiveC
import Darwin
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
    /// 数据来源（调试用）：mediaRemote / local / none
    @Published private(set) var source: String = "none"

    /// 有没有拿到可显示的信息
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

    // MARK: - MediaRemote 私有接口

    /// MRMediaRemoteGetNowPlayingInfo 的函数签名
    private typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
    private typealias GetInfoFunc = @convention(c) (DispatchQueue, InfoBlock) -> Void

    private var getInfo: GetInfoFunc?
    /// 上一次拿到的原始字典，用来在两次刷新之间推进度
    private var lastRaw: [String: Any] = [:]
    private var lastSyncAt: Date = Date()

    private var timer: Timer?

    private init() {
        loadMediaRemote()
        startTimer()
    }

    // MARK: - 加载

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            source = "none"
            return
        }
        guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            source = "none"
            return
        }
        getInfo = unsafeBitCast(sym, to: GetInfoFunc.self)
    }

    // MARK: - 定时刷新

    private func startTimer() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // 立刻读一次
        refresh()
    }

    /// 主动刷一次
    func refresh() {
        if let fn = getInfo {
            fn(DispatchQueue.main) { [weak self] dict in
                guard let self = self else { return }
                if let d = dict as? [String: Any], !d.isEmpty {
                    self.apply(raw: d, from: "mediaRemote")
                } else {
                    // MediaRemote 没数据，试本地的
                    self.readLocal()
                }
            }
        } else {
            readLocal()
        }
    }

    /// 回退方案：读本 App 的 nowPlayingInfo（一般拿不到别人的）
    private func readLocal() {
        if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo, !info.isEmpty {
            var d: [String: Any] = [:]
            d[kMRTitle] = info[MPMediaItemPropertyTitle]
            d[kMRArtist] = info[MPMediaItemPropertyArtist]
            d[kMRDuration] = info[MPMediaItemPropertyPlaybackDuration]
            d[kMRElapsed] = info[MPNowPlayingInfoPropertyElapsedPlaybackTime]
            d[kMRRate] = info[MPNowPlayingInfoPropertyPlaybackRate]
            if let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
                artwork = art.image(at: CGSize(width: 120, height: 120))
            }
            apply(raw: d, from: "local", skipArtwork: true)
        } else {
            // 真没有了，清空
            if !title.isEmpty {
                title = ""
                artist = ""
                elapsed = 0
                duration = 0
                artwork = nil
                isPlaying = false
                source = "none"
            }
        }
    }

    // MARK: - 解析字典

    // MediaRemote 的 key 就是这些字符串本身
    private let kMRTitle = "kMRMediaRemoteNowPlayingInfoTitle"
    private let kMRArtist = "kMRMediaRemoteNowPlayingInfoArtist"
    private let kMRAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
    private let kMRDuration = "kMRMediaRemoteNowPlayingInfoDuration"
    private let kMRElapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    private let kMRRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    private let kMRArtwork = "kMRMediaRemoteNowPlayingInfoArtworkData"

    private func apply(raw: [String: Any], from src: String, skipArtwork: Bool = false) {
        let t = (raw[kMRTitle] as? String) ?? ""
        let a = (raw[kMRArtist] as? String) ?? ""

        // 没有歌名就当作没在播
        guard !t.isEmpty else {
            if !title.isEmpty {
                title = ""
                artist = ""
                elapsed = 0
                duration = 0
                artwork = nil
                isPlaying = false
                source = "none"
            }
            return
        }

        title = t
        artist = a
        source = src

        duration = num(raw[kMRDuration])
        elapsed = num(raw[kMRElapsed])
        let rate = num(raw[kMRRate])
        isPlaying = rate > 0.01

        // 封面（只解一次，避免每秒都解码）
        if !skipArtwork, artwork == nil, let data = raw[kMRArtwork] as? Data {
            artwork = UIImage(data: data)
        }

        lastRaw = raw
        lastSyncAt = Date()
    }

    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
}
