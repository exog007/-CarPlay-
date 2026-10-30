//
//  AppTheme.swift
//  外观主题（背景 + 仪表颜色），全部可自定义并存本地
//

import SwiftUI
import UIKit

// MARK: - 背景类型

enum BackgroundType: String, Codable, CaseIterable {
    case solid      // 纯色
    case gradient   // 渐变
    case preset     // 预设主题
    case photo      // 相册图片

    var title: String {
        switch self {
        case .solid:    return "纯色"
        case .gradient: return "渐变"
        case .preset:   return "主题"
        case .photo:    return "图片"
        }
    }
}

// MARK: - 仪表风格

/// 横屏仪表皮肤
enum DashStyle: String, Codable, CaseIterable, Identifiable {
    /// 标准：卡片式，速度/档位/电压功率三栏
    case standard
    /// 竞技：黑底琥珀线框，EVA 诊断屏风格
    case sport
    /// 动态：全屏地图 + 左右圆环 + 顶部四项数据
    case dynamic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准风格"
        case .sport:    return "竞技风格"
        case .dynamic:  return "动态仪表"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: return "卡片分栏，速度 / 档位 / 电压功率"
        case .sport:    return "黑底琥珀线框，转速刻度条 + 大号速度"
        case .dynamic:  return "全屏地图 + 左右圆环 + 顶部四项"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "rectangle.split.3x1.fill"
        case .sport:    return "speedometer"
        case .dynamic:  return "map"
        }
    }
}

// MARK: - 预设主题

struct ThemePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let start: String     // hex
    let end: String       // hex
    let isLight: Bool     // 浅色背景？
}

enum ThemePresets {
    static let all: [ThemePreset] = [
        ThemePreset(id: "night",    name: "暗夜",   start: "#0F0F12", end: "#050507", isLight: false),
        ThemePreset(id: "deepsea",  name: "深海",   start: "#0A1B2E", end: "#02060C", isLight: false),
        ThemePreset(id: "carbon",   name: "碳纤维", start: "#1C1C1E", end: "#0A0A0B", isLight: false),
        ThemePreset(id: "rose",     name: "玫红",   start: "#2B0D1A", end: "#12040A", isLight: false),
        ThemePreset(id: "forest",   name: "军绿",   start: "#12210F", end: "#080D07", isLight: false),
        ThemePreset(id: "ice",      name: "冰蓝",   start: "#0C2230", end: "#020A0F", isLight: false),
        ThemePreset(id: "purple",   name: "紫夜",   start: "#1A0F2E", end: "#080414", isLight: false),
        ThemePreset(id: "ember",    name: "余烬",   start: "#2B1408", end: "#100702", isLight: false),
        ThemePreset(id: "steel",    name: "钢灰",   start: "#242A30", end: "#0D1013", isLight: false),
        ThemePreset(id: "milk",     name: "奶白",   start: "#F5F3EE", end: "#E4E1DA", isLight: true),
        ThemePreset(id: "paper",    name: "纸感",   start: "#FAF8F3", end: "#EDEAE2", isLight: true),
        ThemePreset(id: "sky",      name: "晴空",   start: "#E8F2FB", end: "#CFE3F5", isLight: true),
    ]
}

// MARK: - 可调颜色槽

enum ColorSlot: String, CaseIterable, Identifiable {
    case rpm
    case power
    case mosTemp
    case motorTemp
    case voltage
    case current
    case ok
    case warn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rpm:       return "转速"
        case .power:     return "功率"
        case .mosTemp:   return "MOS 温度"
        case .motorTemp: return "电机温度"
        case .voltage:   return "电压"
        case .current:   return "电流"
        case .ok:        return "正常状态"
        case .warn:      return "警告"
        }
    }

    var defaultHex: String {
        switch self {
        case .rpm:       return "#00E5FF"
        case .power:     return "#FF9F0A"
        case .mosTemp:   return "#FF9500"
        case .motorTemp: return "#FF6B9D"
        case .voltage:   return "#FFD60A"
        case .current:   return "#64D2FF"
        case .ok:        return "#32D74B"
        case .warn:      return "#FF453A"
        }
    }
}

// MARK: - 主题模型

struct AppTheme: Codable, Equatable {
    var backgroundType: BackgroundType = .preset
    var presetId: String = "night"
    var solidHex: String = "#0F0F12"
    var gradientStart: String = "#0F0F12"
    var gradientEnd: String = "#050507"

    /// 相册图片文件名（存在 Documents 目录下，只存文件名）
    var photoFileName: String = ""
    /// 图片模糊度 0 ~ 20
    var photoBlur: Double = 0
    /// 图片上压的暗色遮罩 0 ~ 0.8（让文字看得清）
    var photoDim: Double = 0.35

    /// 自定义颜色槽（hex）
    var colorSlots: [String: String] = [:]

    /// 卡片不透明度 0.15 ~ 0.9
    var cardOpacity: Double = 0.75

    /// 横屏仪表风格
    var dashStyle: DashStyle = .standard
    /// 竞技风格底色
    var sportBgHex: String = "#000000"
    /// 竞技风格文字发光强度 0 ~ 1
    var sportGlow: Double = 0.6
    /// 竞技风格背景图文件名（空 = 用纯色底）
    var sportPhotoName: String = ""
    /// 竞技背景图暗度 0 ~ 0.85
    var sportPhotoDim: Double = 0.35
    /// 竞技背景图模糊 0 ~ 20
    var sportPhotoBlur: Double = 0

    /// 转速显示倍率（原厂 100rpm 在竞技仪表上显示成 1000rpm）
    var rpmMultiplier: Double = 10
    /// 转速表满量程（按下显示后的刻度算）
    var rpmScaleMax: Double = 12000

    /// 电压电量表的满电阈值（V）
    var battFullVoltage: Double = 90.3
    /// 电压电量表的没电阈值（V）
    var battEmptyVoltage: Double = 63.0

    /// 字体亮度系数 0.5 ~ 1.6
    ///
    /// 1.0 = 调色板原色。大于 1 高亮（彩色更刺眼），小于 1 压暗（夜里不晃眼）。
    var textBrightness: Double = 1.0

    /// 当前背景是不是浅色
    var isLightBackground: Bool {
        switch backgroundType {
        case .preset:
            return ThemePresets.all.first(where: { $0.id == presetId })?.isLight ?? false
        case .solid:
            return ColorUtil.isLight(hex: solidHex)
        case .gradient:
            // 两端都亮才算浅色
            return ColorUtil.isLight(hex: gradientStart) && ColorUtil.isLight(hex: gradientEnd)
        case .photo:
            // 图片背景：有遮罩就当深色处理，文字用白色更保险
            return photoDim < 0.25
        }
    }

    func color(for slot: ColorSlot) -> Color {
        Color(hex: colorSlots[slot.rawValue] ?? slot.defaultHex).brightnessScaled(textBrightness)
    }

    func hex(for slot: ColorSlot) -> String {
        colorSlots[slot.rawValue] ?? slot.defaultHex
    }

    mutating func setColor(_ hex: String, for slot: ColorSlot) {
        colorSlots[slot.rawValue] = hex
    }

    mutating func resetColors() {
        colorSlots.removeAll()
    }

    /// 前景色（文字）：浅背景用深色
    ///
    /// 亮度系数直接乘在这个颜色上：0.6 偏暗（不晃眼），1.0 正常，1.5 高亮
    var foreground: Color {
        let base: Color = isLightBackground ? Color(white: 0.12) : Color.white
        return base.brightnessScaled(textBrightness)
    }

    /// 次要文字
    var secondaryForeground: Color {
        let base: Color = isLightBackground ? Color(white: 0.38) : Color(white: 0.65)
        return base.brightnessScaled(textBrightness)
    }

    /// 卡片底色
    var cardBackground: Color {
        if isLightBackground {
            return Color.white.opacity(cardOpacity)
        }
        return Color.white.opacity(cardOpacity * 0.16)
    }

    /// 卡片描边
    var cardStroke: Color {
        isLightBackground ? Color.black.opacity(0.08) : Color.white.opacity(0.06)
    }

    // MARK: 持久化

    private static let key = "appTheme"

    /// 老版本存档没有新字段，用默认值补齐
    init() {}

    enum CodingKeys: String, CodingKey {
        case backgroundType, presetId, solidHex, gradientStart, gradientEnd
        case photoFileName, photoBlur, photoDim
        case colorSlots, cardOpacity
        case dashStyle, sportBgHex, sportGlow
        case sportPhotoName, sportPhotoDim, sportPhotoBlur
        case rpmMultiplier, rpmScaleMax
        case battFullVoltage, battEmptyVoltage
        case textBrightness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backgroundType = (try? c.decode(BackgroundType.self, forKey: .backgroundType)) ?? .preset
        presetId       = (try? c.decode(String.self, forKey: .presetId)) ?? "night"
        solidHex       = (try? c.decode(String.self, forKey: .solidHex)) ?? "#0F0F12"
        gradientStart  = (try? c.decode(String.self, forKey: .gradientStart)) ?? "#0F0F12"
        gradientEnd    = (try? c.decode(String.self, forKey: .gradientEnd)) ?? "#050507"
        photoFileName  = (try? c.decode(String.self, forKey: .photoFileName)) ?? ""
        photoBlur      = (try? c.decode(Double.self, forKey: .photoBlur)) ?? 0
        photoDim       = (try? c.decode(Double.self, forKey: .photoDim)) ?? 0.35
        colorSlots     = (try? c.decode([String: String].self, forKey: .colorSlots)) ?? [:]
        cardOpacity    = (try? c.decode(Double.self, forKey: .cardOpacity)) ?? 0.75
        dashStyle      = (try? c.decode(DashStyle.self, forKey: .dashStyle)) ?? .standard
        sportBgHex     = (try? c.decode(String.self, forKey: .sportBgHex)) ?? "#000000"
        sportGlow      = (try? c.decode(Double.self, forKey: .sportGlow)) ?? 0.6
        sportPhotoName = (try? c.decode(String.self, forKey: .sportPhotoName)) ?? ""
        sportPhotoDim  = (try? c.decode(Double.self, forKey: .sportPhotoDim)) ?? 0.35
        sportPhotoBlur = (try? c.decode(Double.self, forKey: .sportPhotoBlur)) ?? 0
        rpmMultiplier  = (try? c.decode(Double.self, forKey: .rpmMultiplier)) ?? 10
        rpmScaleMax    = (try? c.decode(Double.self, forKey: .rpmScaleMax)) ?? 12000
        battFullVoltage  = (try? c.decode(Double.self, forKey: .battFullVoltage)) ?? 90.3
        battEmptyVoltage = (try? c.decode(Double.self, forKey: .battEmptyVoltage)) ?? 63.0
        textBrightness   = (try? c.decode(Double.self, forKey: .textBrightness)) ?? 1.0
    }

    static func load() -> AppTheme {
        guard let data = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(AppTheme.self, from: data) else {
            return AppTheme()
        }
        return t
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - 背景图片存取

enum BackgroundImageStore {

    /// 图片放这里：Documents/bg-photo.jpg
    static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("bg-photo.jpg")
    }

    /// 存一张图（会压到合理尺寸，防止内存爆掉）
    /// - Returns: 是否成功
    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        guard let url = fileURL else { return false }
        // 按屏幕宽度缩一下，竖屏也够用
        let maxSide: CGFloat = 1600
        let scaled = image.resized(maxSide: maxSide)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 读图
    static func load() -> UIImage? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func delete() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static var exists: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - 竞技风格背景图存取
//
// 和普通背景图分开存：Documents/sport-bg.jpg
// 这样切换风格时两张图互不干扰。

enum SportBackgroundStore {

    static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("sport-bg.jpg")
    }

    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        guard let url = fileURL else { return false }
        // 横屏铺满，最长边 2400 足够
        let scaled = image.resized(maxSide: 2400)
        guard let data = scaled.jpegData(compressionQuality: 0.88) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func load() -> UIImage? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func delete() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static var exists: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

extension UIImage {
    /// 等比缩放到最长边不超过 maxSide
    func resized(maxSide: CGFloat) -> UIImage {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return self }
        let longest = max(w, h)
        guard longest > maxSide else { return self }
        let ratio = maxSide / longest
        let newSize = CGSize(width: w * ratio, height: h * ratio)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: fmt)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - 颜色工具

enum ColorUtil {

    /// "#RRGGBB" → Color
    static func color(hex: String) -> Color {
        Color(hex: hex)
    }

    /// 判断是不是浅色
    static func isLight(hex: String) -> Bool {
        let (r, g, b) = rgb(hex: hex)
        // 相对亮度（sRGB 近似）
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum > 0.55
    }

    /// hex → (r,g,b) 0...1
    static func rgb(hex: String) -> (Double, Double, Double) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return (0, 0, 0) }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return (r, g, b)
    }

    /// (r,g,b) 0...1 → hex
    static func hex(r: Double, g: Double, b: Double) -> String {
        let ri = Int((max(0, min(1, r)) * 255).rounded())
        let gi = Int((max(0, min(1, g)) * 255).rounded())
        let bi = Int((max(0, min(1, b)) * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    /// 预置色板（挑过的好看颜色）
    static let palette: [String] = [
        "#00E5FF", "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#FF453A",
        "#FF9F0A", "#FFD60A", "#32D74B", "#30D158", "#64D2FF", "#FF6B9D",
        "#A2845E", "#8E8E93", "#FFFFFF", "#0F0F12",
    ]
}

// MARK: - Color(hex:) 扩展

extension Color {
    init(hex: String) {
        let (r, g, b) = ColorUtil.rgb(hex: hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// 转回 #RRGGBB（给 ColorPicker 用）
    func toHex() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }

    /// 按系数调整亮度
    ///
    /// 系数 > 1 时往白色方向提，< 1 时整体压暗。
    /// 直接乘 RGB 会让暗色更暗、亮色更亮，色相基本保持。
    func brightnessScaled(_ factor: Double) -> Color {
        let f = min(max(factor, 0.05), 2.0)
        if abs(f - 1.0) < 0.001 { return self }
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        if f <= 1.0 {
            // 压暗
            return Color(.sRGB, red: r * f, green: g * f, blue: b * f, opacity: a)
        }
        // 提亮：往 1.0 插值，避免过曝后完全变白
        let t = (f - 1.0) / 1.0
        return Color(.sRGB,
                     red: r + (1 - r) * t,
                     green: g + (1 - g) * t,
                     blue: b + (1 - b) * t,
                     opacity: a)
    }
}
