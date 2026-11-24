//
//  DataSource.swift
//  数据源选择：远驱 / ymobd 汽车 / 标准 OBD2 汽车 / 摩托车
//
//  四者互斥：选哪个就只启动哪个，不会同时抢占蓝牙。
//
//  三个 OBD 数据源共用同一套读取代码，但：
//   · 握手序列不同（ymobd 版有私有授权指令）
//   · 适配器记忆、协议、主题、布局各自独立
//

import Foundation
import Combine

enum DataSource: String, CaseIterable, Identifiable {
    /// 远驱控制器（电动车 / 电摩）
    case fardriver  = "fardriver"

    /// ymobd 兼容模式（特殊 ELM327 变体）
    ///
    /// 有些适配器只认 ymobd 的握手序列：
    ///   ATH1（保持 CAN 头）+ ATSP0（自动选协议）+ AT+CRYPT（授权）
    /// 普通 ELM327 不需要这些，发了反而可能出问题。
    case obdYmobd   = "obdYmobd"

    /// 标准 OBD2 汽车（ELM327 / Vgate iCar Pro 等）
    ///
    /// 走最标准的 ELM327 流程：
    ///   ATZ → ATE0 → ATL0 → ATS0 → ATSPn → 0100
    /// 兼容绝大多数适配器。
    case obd2       = "obd2"

    /// OBD2 摩托车
    ///
    /// 同上，但默认协议偏向 KWP2000 / ISO9141（摩托常用）。
    case motorcycle = "motorcycle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fardriver:  return "远驱控制器（电动车/电摩）"
        case .obdYmobd:   return "OBD2（ymobd 兼容模式）"
        case .obd2:       return "OBD2（标准汽车）"
        case .motorcycle: return "OBD2（摩托车）"
        }
    }

    var shortTitle: String {
        switch self {
        case .fardriver:  return "远驱"
        case .obdYmobd:   return "ymobd"
        case .obd2:       return "OBD2"
        case .motorcycle: return "摩托车"
        }
    }

    var subtitle: String {
        switch self {
        case .fardriver:
            return "通过远驱 BLE 控制器读取电压/电流/转速/温度"
        case .obdYmobd:
            return "ymobd 专用握手（ATH1 + ATSP0 + AT+CRYPT）"
        case .obd2:
            return "标准 ELM327 / Vgate iCar Pro，读转速/车速/水温/故障码"
        case .motorcycle:
            return "摩托车 OBD 适配器，支持 KWP2000 / ISO 9141"
        }
    }

    var icon: String {
        switch self {
        case .fardriver:  return "bolt.car.fill"
        case .obdYmobd:   return "car.side.fill"
        case .obd2:       return "car.fill"
        case .motorcycle: return "motorcycle.fill"
        }
    }

    /// 是不是 OBD 系列（三个 OBD 数据源）
    ///
    /// 仪表据此隐藏电机 / BMS 区块，设置据此显示 OBD 相关选项。
    var isObdFamily: Bool {
        self == .obdYmobd || self == .obd2 || self == .motorcycle
    }

    /// 用 ymobd 特殊握手
    var usesYmobdHandshake: Bool {
        self == .obdYmobd
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

    /// 是不是 OBD 模式（三个 OBD 数据源都算）
    static var isObd: Bool { current.isObdFamily }

    /// 是不是摩托车模式
    static var isMotorcycle: Bool { current == .motorcycle }

    /// 是不是 ymobd 兼容模式
    static var isYmobd: Bool { current == .obdYmobd }

    /// 用于区分持久化 key 的前缀
    ///
    ///   ymobd  → ym
    ///   标准汽车 → obd
    ///   摩托   → moto
    ///   远驱   → fd
    var storageKey: String {
        switch self {
        case .fardriver:  return "fd"
        case .obdYmobd:   return "ym"
        case .obd2:       return "obd"
        case .motorcycle: return "moto"
        }
    }
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
