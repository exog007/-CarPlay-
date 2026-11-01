//
//  BootVideo.swift
//  开机动画：用户上传一段视频，进入竞技仪表前先播完，再放自检动画
//
//  视频存在 Documents/boot-video.mp4，播多久就等多久，
//  播完自动进入竞技仪表自检画面。
//

import Foundation
import AVFoundation
import Combine

final class BootVideo: NSObject, ObservableObject {

    static let shared = BootVideo()

    /// 有没有自定义开机视频
    @Published private(set) var hasVideo = false
    /// 视频时长（秒）
    @Published private(set) var duration: Double = 0

    /// 开关：只有勾选了才播开机动画
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "bootVideoEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "bootVideoEnabled") }
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
        return dir.appendingPathComponent("boot-video.mp4")
    }

    func refreshInfo() {
        guard let url = Self.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            hasVideo = false
            duration = 0
            return
        }
        hasVideo = true
        let asset = AVURLAsset(url: url)
        let d = CMTimeGetSeconds(asset.duration)
        duration = (d.isFinite && d > 0) ? d : 0
    }

    // MARK: - 导入

    /// 从相册或文件导入视频，转成 mp4 存到 Documents
    /// - Returns: 是否成功
    @discardableResult
    func importVideo(from url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)

        // 必须有视频轨
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              !videoTracks.isEmpty else {
            return false
        }

        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetHighestQuality)
                ?? AVAssetExportSession(asset: asset,
                                        presetName: AVAssetExportPreset1280x720)
                ?? AVAssetExportSession(asset: asset,
                                        presetName: AVAssetExportPresetMediumQuality) else {
            return false
        }
        guard let out = Self.fileURL else { return false }
        try? FileManager.default.removeItem(at: out)

        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

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

    func deleteVideo() {
        guard let url = Self.fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        hasVideo = false
        duration = 0
        Self.enabled = false
    }
}
