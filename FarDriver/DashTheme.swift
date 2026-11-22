//
//  DashTheme.swift
//  仪表独立主题：电动车（远驱）和 OBD2 各自一套完整的视觉配置
//
//  解决的问题：之前「竞技底色 / 背景图 / 发光 / 仪表颜色」是全局共用的，
//  切到 OBD2 模式后还是电动车那一套。现在两套独立保存，互不干扰。
//

import Foundation
import SwiftUI
import Combine

// MARK: - 主题主体

/// 一套仪表视觉配置
struct DashTheme: Codable, Equatable {

    // ── 背景 ──

    /// 背景类型
    enum BackgroundKind: String, Codable, CaseIterable, Identifiable {
        case solid          // 纯色
        case photo          // 静态图片
        case video          // 视频（动态背景）
        case particles      // 粒子动画（不用素材，纯代码绘制）

        var id: String { rawValue }

        var title: String {
            switch self {
            case .solid:     return "纯色"
            case .photo:     return "图片"
            case .video:     return "视频"
            case .particles: return "动态粒子"
            }
        }

        var icon: String {
            switch self {
            case .solid:     return "paintpalette"
            case .photo:     return "photo"
            case .video:     return "video.fill"
            case .particles: return "sparkles"
            }
        }
    }

    enum ParticleStyle: String, Codable, CaseIterable, Identifiable {
        case starfield      // 星流（向前飞的星星）
        case rain           // 雨丝
        case grid           // 透视网格（赛博）
        case bokeh          // 光斑飘动

        var id: String { rawValue }

        var title: String {
            switch self {
            case .starfield: return "星流"
            case .rain:      return "雨丝"
            case .grid:      return "透视网格"
            case .bokeh:     return "光斑"
            }
        }

        var icon: String {
            switch self {
            case .starfield: return "sparkle"
            case .rain:      return "cloud.rain"
            case .grid:      return "square.grid.3x3"
            case .bokeh:     return "circle.grid.cross"
            }
        }
    }

    /// 背景类型
    var backgroundKind: BackgroundKind = .solid
    /// 纯色背景
    var bgHex: String = "#000000"
    /// 静态背景图文件名（存在 Documents/themes/ 下）
    var photoName: String = ""
    /// 视频背景文件名
    var videoName: String = ""
    /// 图片/视频暗度 0 ~ 0.85
    var mediaDim: Double = 0.35
    /// 图片/视频模糊 0 ~ 20
    var mediaBlur: Double = 0
    /// 粒子样式
    var particleStyle: ParticleStyle = .starfield
    /// 粒子密度 0.2 ~ 1
    var particleIntensity: Double = 0.6
    /// 粒子速度 0.3 ~ 3
    var particleSpeed: Double = 1.0
    /// 视频是不是静音（背景视频通常静音）
    var videoMuted: Bool = true

    // ── 颜色 ──

    /// 强调色（速度数字、档位高亮）
    var accentHex: String = "#FF9F0A"
    /// 转速色
    var rpmHex: String = "#00E5FF"
    /// 正常状态色
    var okHex: String = "#32D74B"
    /// 警告色
    var warnHex: String = "#FF453A"

    // ── 效果 ──

    /// 发光强度 0 ~ 1
    var glow: Double = 0.6
    /// 字体亮度 0.5 ~ 1.6
    var brightness: Double = 1.0

    // MARK: - 预设

    /// 电动车默认：黑底琥珀
    static let fardriverDefault = DashTheme(
        backgroundKind: .solid,
        bgHex: "#000000",
        accentHex: "#FF9F0A",
        rpmHex: "#00E5FF",
        okHex: "#32D74B",
        warnHex: "#FF453A"
    )

    /// OBD2 默认：深蓝底青绿（汽车仪表感觉）
    static let obd2Default = DashTheme(
        backgroundKind: .solid,
        bgHex: "#050A14",
        accentHex: "#35D0FF",
        rpmHex: "#7DF9FF",
        okHex: "#2EE59D",
        warnHex: "#FF5A52"
    )

    // MARK: - 便捷取色

    var accentColor: Color { Color(hex: accentHex) }
    var rpmColor: Color { Color(hex: rpmHex) }
    var okColor: Color { Color(hex: okHex) }
    var warnColor: Color { Color(hex: warnHex) }
    var bgColor: Color { Color(hex: bgHex) }
}

// MARK: - 主题存储

/// 两套主题的存取
///
/// 存在 UserDefaults 里（JSON），文件名再指向 Documents/themes/ 下的素材。
///
/// 继承 ObservableObject：设置里改完立刻通知仪表重绘，
/// 不用关掉页面或重启 App。
final class DashThemeStore: ObservableObject {

    static let shared = DashThemeStore()

    /// 主题变更版本号，仪表监听它来重绘
    @Published private(set) var revision: Int = 0

    /// 当前编辑/显示哪一套（跟数据源走）
    private func key(_ source: DataSource) -> String {
        source == .obd2 ? "dashThemeObd2" : "dashThemeFarDriver"
    }

    func theme(for source: DataSource) -> DashTheme {
        let k = key(source)
        if let data = UserDefaults.standard.data(forKey: k),
           let t = try? JSONDecoder().decode(DashTheme.self, from: data) {
            return t
        }
        return source == .obd2 ? .obd2Default : .fardriverDefault
    }

    func save(_ theme: DashTheme, for source: DataSource) {
        guard let data = try? JSONEncoder().encode(theme) else { return }
        UserDefaults.standard.set(data, forKey: key(source))
        revision += 1
    }

    /// 恢复某一套的默认值
    func reset(_ source: DataSource) {
        save(source == .obd2 ? .obd2Default : .fardriverDefault, for: source)
    }

    // MARK: - 素材文件

    /// 素材目录：Documents/themes/
    static var mediaDir: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("themes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 按文件名取素材 URL
    static func mediaURL(_ name: String) -> URL? {
        guard !name.isEmpty, let dir = mediaDir else { return nil }
        let u = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 存一张图片，返回文件名
    static func saveImage(_ image: UIImage, prefix: String) -> String? {
        guard let dir = mediaDir else { return nil }
        let name = "\(prefix)-\(UUID().uuidString.prefix(8)).jpg"
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// 存一段视频（原样复制），返回文件名
    static func saveVideo(from src: URL, prefix: String) -> String? {
        guard let dir = mediaDir else { return nil }
        var ext = src.pathExtension.lowercased()
        if ext.isEmpty { ext = "mp4" }
        if !["mp4", "mov", "m4v"].contains(ext) { ext = "mp4" }
        let name = "\(prefix)-\(UUID().uuidString.prefix(8)).\(ext)"
        let dst = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return name
        } catch {
            return nil
        }
    }

    /// 删掉某个素材文件
    static func deleteMedia(_ name: String) {
        guard !name.isEmpty, let dir = mediaDir else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}
