//
//  GpsRefreshRate.swift
//  GPS 刷新率档位
//
//  iOS 不允许 App 直接指定定位频率，系统会自己决定给点节奏。
//  我们能控制的是「拿到点之后怎么追」——也就是平滑定时器的频率和追赶系数。
//
//  这里给几档可选：
//    省电   ：30 Hz 平滑，追 20%  —— 数字变化柔和，最省电
//    标准   ：60 Hz 平滑，追 30%  —— 默认，平衡
//    快速   ：120 Hz 平滑，追 42% —— 跟脚
//    极速   ：120 Hz 平滑，追 70% —— 最跟脚，GPS 抖动会透出来
//
//  刷新率越高越跟脚，但也越容易看到 GPS 的抖动噪声。
//

import Foundation

/// GPS 刷新率档位
enum GpsRefreshRate: String, CaseIterable, Identifiable {
    case battery = "battery"
    case standard = "standard"
    case fast = "fast"
    case ultra = "ultra"

    var id: String { rawValue }

    /// @AppStorage 需要 RawRepresentable，String 枚举自带，这里补上显式声明
    /// （Swift 会为 String 原始值枚举自动合成，写出来是为了清楚）

    var title: String {
        switch self {
        case .battery:  return "省电（30 Hz）"
        case .standard: return "标准（60 Hz）"
        case .fast:     return "快速（120 Hz）"
        case .ultra:    return "极速（120 Hz+）"
        }
    }

    var subtitle: String {
        switch self {
        case .battery:  return "平滑柔和，耗电最低"
        case .standard: return "默认，性能和续航平衡"
        case .fast:     return "跟随更紧，速度数字更跟脚"
        case .ultra:    return "最跟脚，但 GPS 抖动会透出来"
        }
    }

    /// 平滑定时器频率（Hz）
    var timerHz: Double {
        switch self {
        case .battery:  return 30
        case .standard: return 60
        case .fast:     return 120
        case .ultra:    return 120
        }
    }

    /// 每帧追赶系数
    ///
    /// 0.20 → 约 0.2 秒追到 90%
    /// 0.30 → 约 0.15 秒
    /// 0.42 → 约 0.1 秒
    /// 0.70 → 约 0.05 秒
    var smoothFactor: Double {
        switch self {
        case .battery:  return 0.20
        case .standard: return 0.30
        case .fast:     return 0.42
        case .ultra:    return 0.70
        }
    }

    /// 定时器容差
    var tolerance: TimeInterval {
        switch self {
        case .battery:  return 0.01
        case .standard: return 0.005
        case .fast, .ultra: return 0
        }
    }

    /// 变化多少才提交（阈值越小越灵敏，也越容易抖动）
    var publishThreshold: Double {
        switch self {
        case .battery:  return 0.02
        case .standard: return 0.01
        case .fast:     return 0.005
        case .ultra:    return 0.002
        }
    }

    // MARK: - 存取

    private static let key = "gpsRefreshRate"

    /// 当前设置
    static var current: GpsRefreshRate {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? ""
            return GpsRefreshRate(rawValue: raw) ?? .fast
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
