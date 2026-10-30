//
//  BootSound.swift
//  开机自检音效：支持从相册选视频、从文件选音频
//
//  选好的音效会抽成 m4a 存到 Documents/boot-sound.m4a，
//  自检动画开始时播放一次。
//

import Foundation
import AVFoundation
import Combine

final class BootSound: NSObject, ObservableObject {

    static let shared = BootSound()

    /// 播放器（保持引用，不然播到一半会被释放）
    private var player: AVAudioPlayer?

    /// 有没有自定义音效
    @Published private(set) var hasSound = false
    /// 音效时长（秒），给界面显示
    @Published private(set) var duration: Double = 0

    /// 音效开关（默认开）
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "bootSoundEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "bootSoundEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "bootSoundEnabled") }
    }

    private override init() {
        super.init()
        refreshInfo()
    }

    // MARK: - 文件位置

    static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("boot-sound.m4a")
    }

    /// 重新读一次文件信息
    func refreshInfo() {
        guard let url = Self.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            hasSound = false
            duration = 0
            return
        }
        hasSound = true
        if let p = try? AVAudioPlayer(contentsOf: url) {
            duration = p.duration
        } else {
            duration = 0
        }
    }

    // MARK: - 导入

    /// 从任意媒体文件（视频或音频）导入，抽出音轨存成 m4a
    /// - Parameter url: 源文件（相册导出的临时文件，或「文件」App 里的音频）
    /// - Returns: 是否成功
    @discardableResult
    func importMedia(from url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)

        // 检查有没有音轨
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return false
        }
        _ = audioTrack

        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        guard let out = Self.fileURL else { return false }
        // 先删旧的
        try? FileManager.default.removeItem(at: out)

        export.outputURL = out
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = false

        // 用 continuation 把回调转成 async
        let ok: Bool = await withCheckedContinuation { cont in
            export.exportAsynchronously {
                cont.resume(returning: export.status == .completed)
            }
        }
        if ok {
            await MainActor.run {
                self.refreshInfo()
            }
        }
        return ok
    }

    // MARK: - 播放

    /// 播放一次自检音效
    func play() {
        guard Self.enabled else { return }
        guard let url = Self.fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            // 和别的 App 的音频共存，不要抢占
            try AVAudioSession.sharedInstance().setCategory(.ambient,
                                                            options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            // 播不出来就静默跳过，不影响自检动画
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // MARK: - 删除

    func deleteSound() {
        guard let url = Self.fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        hasSound = false
        duration = 0
    }
}
