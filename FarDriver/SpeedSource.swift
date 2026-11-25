//
//  SpeedSource.swift
//  速度来源选择
//
//  三个 OBD 数据源都可以单独选速度来源：
//    · OBD：用 PID 010D（车辆 ECU 报的车速）
//    · GPS：用手机定位（精度高、不受 ECU 上报频率限制）
//
//  为什么需要这个：
//    · 有些车 ECU 不上报 010D，或上报的车速有误差
//    · 手机 GPS 的瞬时速度通常比 OBD 更准更快
//    · 电摩/远驱没这个选项（速度来自控制器）
//

import Foundation

/// 速度来源
enum SpeedSource: String, CaseIterable, Identifiable {
    /// 用 OBD 的 PID 010D
    case obd = "obd"
    /// 用手机 GPS
    case gps = "gps"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .obd: return "OBD 车速"
        case .gps: return "GPS 速度"
        }
    }

    var subtitle: String {
        switch self {
        case .obd: return "读取车辆 ECU 上报的 PID 010D"
        case .gps: return "用手机定位，刷新更快更准（需要定位权限）"
        }
    }

    var icon: String {
        switch self {
        case .obd: return "car.fill"
        case .gps: return "location.fill"
        }
    }

    /// 当前数据源的存储键
    private static var storageKey: String {
        "speedSource.\(DataSource.current.storageKey)"
    }

    /// 读当前数据源的设置
    static var current: SpeedSource {
        get {
            let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
            return SpeedSource(rawValue: raw) ?? .obd
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    /// 读指定数据源的设置
    static func get(for src: DataSource) -> SpeedSource {
        let key = "speedSource.\(src.storageKey)"
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return SpeedSource(rawValue: raw) ?? .obd
    }

    /// 写指定数据源的设置
    static func set(_ v: SpeedSource, for src: DataSource) {
        UserDefaults.standard.set(v.rawValue, forKey: "speedSource.\(src.storageKey)")
    }
}
