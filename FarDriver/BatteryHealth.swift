//
//  BatteryHealth.swift
//  电池健康度、充放电剩余时间估算
//
//  ── 健康度算法（按循环次数推算）──
//    三元锂（NCM）  : 循环 2200 次 → 健康度掉到 80%
//    磷酸铁锂（LFP）: 循环 3500 次 → 健康度掉到 80%
//
//    健康度 = 100% − (已循环次数 ÷ 设计寿命) × 20%
//
//    2200 次时：100 − (2200/2200)×20 = 80%      ✓
//    3300 次时：100 − (3300/2200)×20 = 70%
//    4400 次时：100 − (4400/2200)×20 = 60%
//
//  ⚠️ 这是按你给的规则推算的「理论健康度」，不是 BMS 实测容量衰减。
//     真实健康度要以实际可用容量为准，两者可能差几个百分点。
//

import Foundation
import SwiftUI

// MARK: - 电池化学类型

enum BatteryChemistry: String, Codable, CaseIterable {
    case ncm = "三元锂"
    case lfp = "磷酸铁锂"

    /// 设计寿命：健康度掉到 80% 时的循环次数
    var designCycles: Int {
        switch self {
        case .ncm: return 2200
        case .lfp: return 3500
        }
    }

    /// 每次循环掉多少健康度（百分比）
    var lossPerCycle: Double {
        20.0 / Double(designCycles)
    }

    /// 日常充电建议（三代不同）
    var chargingAdvice: [String] {
        switch self {
        case .ncm:
            return [
                "推荐充到 80% 就切断充电器",
                "20% 时尽量开始充电",
                "10% 请及时充电",
            ]
        case .lfp:
            return [
                "推荐充到 90% 就切断充电器",
                "20% 时尽量开始充电",
                "10% 请及时充电",
            ]
        }
    }
}

// MARK: - 健康度等级

enum HealthLevel {
    case healthy    // > 85%
    case watch      // 80% ~ 85%
    case warning    // 70% ~ 80%
    case critical   // < 70%

    var color: Color {
        switch self {
        case .healthy:  return Color(hex: "#32D74B")
        case .watch:    return Color(hex: "#FFD60A")
        case .warning:  return Color(hex: "#FFD60A")
        case .critical: return Color(hex: "#FF453A")
        }
    }

    var title: String {
        switch self {
        case .healthy:  return "健康"
        case .watch:    return "注意"
        case .warning:  return "需留意"
        case .critical: return "严重"
        }
    }

    /// 要不要亮三角感叹号
    var showsTriangle: Bool {
        self == .warning || self == .critical
    }

    /// 三角图标的名字
    var triangleIcon: String {
        "exclamationmark.triangle.fill"
    }

    /// 提示文案
    var message: String? {
        switch self {
        case .healthy, .watch:
            return nil
        case .warning:
            return "健康度到达 80%，电池性能下降较大，请注意不要进行过充过放。正常使用情况下 80% 是安全范围。"
        case .critical:
            return "健康度到达 70%，不推荐再进行使用，会有很大安全隐患。"
        }
    }

    static func from(soh: Double) -> HealthLevel {
        if soh < 70 { return .critical }
        if soh < 80 { return .warning }
        if soh < 85 { return .watch }
        return .healthy
    }
}

// MARK: - 健康度计算

struct BatteryHealth {

    /// 算健康度
    /// - Parameters:
    ///   - cycles: 已循环次数（BMS 上报）
    ///   - chemistry: 电池类型
    /// - Returns: 健康度百分比 0~100；读不到循环次数时返回 nil
    static func soh(cycles: Int, chemistry: BatteryChemistry) -> Double? {
        guard cycles >= 0 else { return nil }
        let loss = Double(cycles) * chemistry.lossPerCycle
        let soh = 100.0 - loss
        // 低于 0 就按 0 算（实际不可能掉到负）
        return max(0, min(100, soh))
    }

    /// 还能用到多少次循环才掉到 70%
    static func cyclesLeftToCritical(cycles: Int, chemistry: BatteryChemistry) -> Int {
        // 70% 时的循环次数
        let criticalCycles = Int(Double(chemistry.designCycles) * 30.0 / 20.0)
        return max(0, criticalCycles - cycles)
    }

    /// 掉到 70% 的循环次数
    static func criticalCycleCount(chemistry: BatteryChemistry) -> Int {
        Int(Double(chemistry.designCycles) * 30.0 / 20.0)
    }
}

// MARK: - 充放电时间估算

enum ChargeEstimator {

    struct Result {
        var remainingSeconds: TimeInterval
        var isEstimate: Bool      // 是不是粗估（CV 阶段）
        var note: String?
    }

    /// 估充电剩余时间
    /// - Parameters:
    ///   - soc: 当前电量 %
    ///   - capacityTotal: 电池总容量 Ah
    ///   - currentA: 当前电流 A（充电时为正）
    ///   - fullCurrentA: 满功率充电电流 A（用来判断是否进入 CV 阶段）
    static func chargeRemaining(soc: Int,
                                capacityTotal: Double,
                                currentA: Double,
                                fullCurrentA: Double) -> Result? {
        guard capacityTotal > 0, currentA > 0.5 else { return nil }
        let remainingAh = Double(100 - soc) / 100.0 * capacityTotal
        guard remainingAh > 0 else { return nil }

        var seconds = remainingAh / currentA * 3600.0
        var isEstimate = false
        var note: String?

        // CV 阶段（电流掉到满电流一半以下）：速度会越来越慢，粗估要放大
        if fullCurrentA > 0 && currentA < fullCurrentA * 0.5 {
            isEstimate = true
            note = "恒压阶段，电流在减小，时间不准"
            // 经验修正：CV 阶段通常比线性估算多 1.5~2 倍
            seconds *= 1.7
        }

        return Result(remainingSeconds: seconds, isEstimate: isEstimate, note: note)
    }

    /// 估放电剩余时间
    /// - Parameters:
    ///   - soc: 当前电量 %
    ///   - capacityTotal: 电池总容量 Ah
    ///   - currentA: 当前电流 A（放电时为负）
    static func dischargeRemaining(soc: Int,
                                   capacityTotal: Double,
                                   currentA: Double) -> Result? {
        let draw = abs(currentA)
        guard capacityTotal > 0, draw > 0.5 else { return nil }
        // 不放到 0，留 10% 安全余量
        let usableSoc = max(0, soc - 10)
        let usableAh = Double(usableSoc) / 100.0 * capacityTotal
        guard usableAh > 0 else { return nil }

        let seconds = usableAh / draw * 3600.0
        return Result(remainingSeconds: seconds, isEstimate: false, note: "按剩余电量估算，留 10% 余量")
    }

    /// 秒 → "2 小时 11 分"
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return "\(h) 小时 \(m) 分"
        }
        return "\(m) 分"
    }
}
