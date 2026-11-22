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

// MARK: - 变速箱类型（决定档位框长什么样）

/// 变速箱类型
///
/// 自动挡（手自一体）：横排显示 P R N D，挂手动时额外显示 M + 档位数字
/// 纯手动挡：只显示当前一个字符（N / 1 / 2 / 3 ...）
enum GearboxMode: String, CaseIterable, Identifiable {
    /// 自动挡（含手自一体）
    case auto
    /// 纯手动挡
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:   return "自动挡（手自一体）"
        case .manual: return "手动挡"
        }
    }

    var subtitle: String {
        switch self {
        case .auto:   return "横排 P R N D，手动时显示 M 和档位数字"
        case .manual: return "只显示当前档位一个字（N / 1 / 2 / 3…）"
        }
    }

    static var current: GearboxMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "gearboxMode") ?? ""
            return GearboxMode(rawValue: raw) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gearboxMode") }
    }
}

// MARK: - 手动档位（车不支持 PID A4 时用）

/// OBD2 档位的显示方式
///
/// 大多数车读不到真实档位（PID A4 不支持），
/// 这时可以让用户自己指定当前档位，仪表就显示对应格子。
enum GearDisplayMode: String, CaseIterable, Identifiable {
    /// 自动：读 PID A4，读不到就按转速/车速粗判
    case auto
    /// 固定自动挡 D
    case drive
    /// 固定空挡 N
    case neutral
    /// 固定倒挡 R
    case reverse
    /// 固定驻车 P
    case park
    /// 手动 1 档
    case m1
    case m2
    case m3
    case m4
    case m5
    case m6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:    return "自动识别"
        case .drive:   return "D 前进"
        case .neutral: return "N 空挡"
        case .reverse: return "R 倒挡"
        case .park:    return "P 驻车"
        case .m1:      return "M1"
        case .m2:      return "M2"
        case .m3:      return "M3"
        case .m4:      return "M4"
        case .m5:      return "M5"
        case .m6:      return "M6"
        }
    }

    /// 对应的档位
    var gear: ObdGear? {
        switch self {
        case .auto:    return nil            // 交给自动判断
        case .drive:   return .drive
        case .neutral: return .neutral
        case .reverse: return .reverse
        case .park:    return .park
        case .m1:      return .manual(1)
        case .m2:      return .manual(2)
        case .m3:      return .manual(3)
        case .m4:      return .manual(4)
        case .m5:      return .manual(5)
        case .m6:      return .manual(6)
        }
    }

    static var current: GearDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "gearDisplayMode") ?? ""
            return GearDisplayMode(rawValue: raw) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gearDisplayMode") }
    }
}

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
