//
//  AppTheme.swift
//  外观主题（背景 + 仪表颜色），全部可自定义并存本地
//

import SwiftUI

// MARK: - 背景类型

enum BackgroundType: String, Codable, CaseIterable {
    case solid      // 纯色
    case gradient   // 渐变
    case preset     // 预设主题

    var title: String {
        switch self {
        case .solid:    return "纯色"
        case .gradient: return "渐变"
        case .preset:   return "预设主题"
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

    /// 自定义颜色槽（hex）
    var colorSlots: [String: String] = [:]

    /// 卡片不透明度 0.15 ~ 0.9
    var cardOpacity: Double = 0.75

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
        }
    }

    func color(for slot: ColorSlot) -> Color {
        Color(hex: colorSlots[slot.rawValue] ?? slot.defaultHex)
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
    var foreground: Color {
        isLightBackground ? Color(white: 0.12) : Color.white
    }

    /// 次要文字
    var secondaryForeground: Color {
        isLightBackground ? Color(white: 0.38) : Color(white: 0.65)
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
}
