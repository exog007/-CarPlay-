//
//  DataSource.swift
//  数据源选择：远驱控制器 / OBD2 汽车摩托
//
//  两者互斥：选哪个就只启动哪个，不会同时抢占蓝牙。
//

import Foundation
import Combine

enum DataSource: String, CaseIterable, Identifiable {
    case fardriver = "fardriver"
    case obd2      = "obd2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fardriver: return "远驱控制器（电动车/电摩）"
        case .obd2:      return "OBD2（汽车/摩托车）"
        }
    }

    var shortTitle: String {
        switch self {
        case .fardriver: return "远驱"
        case .obd2:      return "OBD2"
        }
    }

    var subtitle: String {
        switch self {
        case .fardriver: return "通过远驱 BLE 控制器读取电压/电流/转速/温度"
        case .obd2:      return "通过 ELM327 适配器读取转速/车速/水温/电瓶电压/故障码"
        }
    }

    var icon: String {
        switch self {
        case .fardriver: return "bolt.car.fill"
        case .obd2:      return "car.fill"
        }
    }

    /// 读当前选择
    static var current: DataSource {
        get {
            let raw = UserDefaults.standard.string(forKey: "dataSource") ?? ""
            return DataSource(rawValue: raw) ?? .fardriver
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "dataSource")
        }
    }

    /// 是不是 OBD2 模式（仪表据此隐藏电机/BMS 区块）
    static var isObd: Bool { current == .obd2 }
}

// MARK: - 报警阈值设置

/// 故障灯触发阈值（持久化，设置页可调）
///
/// 设置页用 @AppStorage 直接读写同名 key，
/// 仪表这边通过这里读，保证两边一致。
enum AlarmThreshold {

    /// 水温报警阈值（°C）的 UserDefaults key
    static let coolantHighKey = "alarmCoolantHigh"
    /// 电瓶电压报警阈值（V）的 UserDefaults key
    static let batteryLowKey = "alarmBatteryLow"

    /// 水温报警阈值（°C），高于它就亮水温灯
    ///
    /// 默认 105：正常水温 85~95，超过 105 已经是过热
    static var coolantHigh: Double {
        get {
            let v = UserDefaults.standard.double(forKey: coolantHighKey)
            return v > 0 ? v : 105
        }
        set { UserDefaults.standard.set(newValue, forKey: coolantHighKey) }
    }

    /// 电瓶电压报警阈值（V），低于它就亮电瓶灯
    ///
    /// 默认 11.8：12V 系统熄火约 12.2~12.6，启动后 13.8~14.4，
    /// 低于 11.8 说明亏电或发电机故障
    static var batteryLow: Double {
        get {
            let v = UserDefaults.standard.double(forKey: batteryLowKey)
            return v > 0 ? v : 11.8
        }
        set { UserDefaults.standard.set(newValue, forKey: batteryLowKey) }
    }
}
