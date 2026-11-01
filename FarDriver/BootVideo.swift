//
//  BootVideo.swift
//  开机动画：用户上传一段视频，进入竞技仪表前先播完，再放自检动画
//
//  ⚠️ 不做转码，直接原样复制文件。
//     之前用 AVAssetExportSession 转 720p，实测会把音轨丢掉（视频没声音），
//     而且转码还会改变画面比例。直接复制能 100% 保留原视频的声音和画质。
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
    /// 视频有没有音轨
    @Published private(set) var hasAudio = false

    /// 开关：只有勾选了才播开机动画
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "bootVideoEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "bootVideoEnabled") }
    }

    /// 存文件时用的扩展名（保留原始格式，避免转换丢音轨）
    private static let extKey = "bootVideoExt"

    private override init() {
        super.init()
        refreshInfo()
    }

    // MARK: - 文件位置

    static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let ext = UserDefaults.standard.string(forKey: extKey) ?? "mp4"
        return dir.appendingPathComponent("boot-video.\(ext)")
    }

    /// 删掉可能残留的旧文件（换扩展名后旧文件还在会占空间）
    private static func removeAllCandidates() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        for ext in ["mp4", "mov", "m4v", "MP4", "MOV", "M4V"] {
            let u = dir.appendingPathComponent("boot-video.\(ext)")
            try? FileManager.default.removeItem(at: u)
        }
    }

    func refreshInfo() {
        guard let url = Self.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            hasVideo = false
            duration = 0
            hasAudio = false
            return
        }
        hasVideo = true
        let asset = AVURLAsset(url: url)
        let d = CMTimeGetSeconds(asset.duration)
        duration = (d.isFinite && d > 0) ? d : 0
        // 读一下有没有音轨，界面上能看出来
        if let tracks = try? asset.loadTracks(withMediaType: .audio) {
            hasAudio = !tracks.isEmpty
        } else {
            hasAudio = false
        }
    }

    // MARK: - 导入

    /// 直接复制原视频文件到 Documents，不做任何转码
    /// - Returns: 是否成功
    @discardableResult
    func importVideo(from url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)

        // 必须有视频轨
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              !videoTracks.isEmpty else {
            return false
        }

        // 清掉旧文件
        Self.removeAllCandidates()

        // 保留原始扩展名，让 AVPlayer 按原格式解码（音频不丢）
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty { ext = "mp4" }
        // 只允许已知容器，其它一律按 mp4 处理
        if !["mp4", "mov", "m4v"].contains(ext) { ext = "mp4" }
        UserDefaults.standard.set(ext, forKey: Self.extKey)

        guard let out = Self.fileURL else { return false }

        do {
            try FileManager.default.copyItem(at: url, to: out)
        } catch {
            return false
        }

        await MainActor.run {
            self.refreshInfo()
        }
        return true
    }

    func deleteVideo() {
        Self.removeAllCandidates()
        UserDefaults.standard.removeObject(forKey: Self.extKey)
        hasVideo = false
        duration = 0
        hasAudio = false
        Self.enabled = false
    }
}
