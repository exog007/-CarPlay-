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

// MARK: - 充电阶段

/// 充电处于哪个阶段
enum ChargePhase {
    case cc          // 恒流：电压低，电流满
    case ccLate      // 恒流末段：电压接近满，开始有降流趋势
    case cv          // 恒压：电压基本不动，电流一直掉

    var title: String {
        switch self {
        case .cc:     return "恒流充电"
        case .ccLate: return "恒流末段"
        case .cv:     return "恒压充电（降流中）"
        }
    }

    var hint: String? {
        switch self {
        case .cc:     return nil
        case .ccLate: return "快到满电了，充电器准备降流"
        case .cv:     return "充电器在降流，速度会越来越慢"
        }
    }
}

// MARK: - 充放电时间估算

enum ChargeEstimator {

    struct Result {
        var remainingSeconds: TimeInterval
        var isEstimate: Bool      // 是不是粗估
        var note: String?
        var phase: ChargePhase?
    }

    // MARK: 阶段判定

    /// 按单体电压判定充电阶段
    /// - Parameters:
    ///   - cellVoltage: 当前单体电压（V），例如 4.28
    ///   - cellFull: 单体满电电压（V），例如 4.30
    ///   - currentA: 当前电流
    ///   - fullCurrentA: 本次充电的峰值电流
    static func phase(cellVoltage: Double,
                      cellFull: Double,
                      currentA: Double,
                      fullCurrentA: Double) -> ChargePhase {
        // 电流掉到峰值 80% 以下 → 已经进入 CV
        let currentDropped = fullCurrentA > 1 && currentA < fullCurrentA * 0.80
        // 单体电压接近满电
        let nearFull = cellVoltage > cellFull - 0.10   // 4.20V 以上

        if currentDropped && nearFull {
            return .cv
        }
        if nearFull {
            return .ccLate
        }
        return .cc
    }

    // MARK: 估充电剩余时间

    /// 估充电剩余时间（分阶段）
    /// - Parameters:
    ///   - soc: 当前电量 %
    ///   - capacityTotal: 电池总容量 Ah
    ///   - currentA: 当前电流 A（充电时为正）
    ///   - fullCurrentA: 本次充电峰值电流 A
    ///   - cellVoltage: 当前单体电压 V
    ///   - cellFull: 单体满电电压 V
    ///   - voltageHistory: 最近的电压采样（用来算电压爬升速度）
    static func chargeRemaining(soc: Int,
                                capacityTotal: Double,
                                currentA: Double,
                                fullCurrentA: Double,
                                cellVoltage: Double = 0,
                                cellFull: Double = 4.3,
                                voltageHistory: [(time: Date, cellVoltage: Double)] = []) -> Result? {
        guard capacityTotal > 0, currentA > 0.5 else { return nil }

        let ph = phase(cellVoltage: cellVoltage,
                       cellFull: cellFull,
                       currentA: currentA,
                       fullCurrentA: fullCurrentA)

        switch ph {
        case .cc:
            // 恒流阶段：用容量算，最准
            let remainingAh = Double(100 - soc) / 100.0 * capacityTotal
            guard remainingAh > 0 else { return nil }
            let seconds = remainingAh / currentA * 3600.0
            return Result(remainingSeconds: seconds,
                          isEstimate: false,
                          note: nil,
                          phase: .cc)

        case .ccLate:
            // 恒流末段：容量法 + 一点保守修正
            let remainingAh = Double(100 - soc) / 100.0 * capacityTotal
            guard remainingAh > 0 else { return nil }
            // 这一段实际比纯线性估算慢 20~40%
            let seconds = remainingAh / currentA * 3600.0 * 1.3
            return Result(remainingSeconds: seconds,
                          isEstimate: true,
                          note: "接近满电，按经验加时",
                          phase: .ccLate)

        case .cv:
            // 恒压阶段：按电压爬升速度算，比按电流准
            if let s = cvRemainingByVoltage(cellVoltage: cellVoltage,
                                            cellFull: cellFull,
                                            history: voltageHistory) {
                return Result(remainingSeconds: s,
                              isEstimate: true,
                              note: "按电压爬升速度推算",
                              phase: .cv)
            }
            // 电压历史不够时，退回按电流算 + 放大
            let remainingAh = Double(100 - soc) / 100.0 * capacityTotal
            guard remainingAh > 0 else { return nil }
            let seconds = remainingAh / currentA * 3600.0 * 2.0
            return Result(remainingSeconds: seconds,
                          isEstimate: true,
                          note: "恒压阶段，粗估",
                          phase: .cv)
        }
    }

    /// 恒压阶段：按电压差的对数关系推算剩余时间
    ///
    /// 锂电 CV 阶段电流指数衰减：I(t) = I₀·e^(-t/τ)
    /// 电压差也随之指数收窄：ΔV(t) = ΔV₀·e^(-t/τ)
    ///
    /// 所以：剩余时间 = Δt × ln(当前差 ÷ 目标差) ÷ ln(上次差 ÷ 当前差)
    ///
    /// - Returns: 剩余秒数；历史不够时返回 nil
    private static func cvRemainingByVoltage(cellVoltage: Double,
                                             cellFull: Double,
                                             history: [(time: Date, cellVoltage: Double)]) -> TimeInterval? {
        // 充满判据：单体到 cellFull - 0.02（留一点余量，实际永远到不了绝对值）
        let target = cellFull - 0.02
        let currentGap = target - cellVoltage
        guard currentGap > 0.001 else { return 0 }

        // 至少要 3 个采样才能算斜率
        guard history.count >= 3 else { return nil }

        // 用最近的一段（最多 8 分钟）
        let now = Date()
        let recent = history.filter { now.timeIntervalSince($0.time) <= 480 && now.timeIntervalSince($0.time) > 30 }
        guard let first = recent.first, let last = recent.last else { return nil }

        let dt = last.time.distance(to: first.time) * -1   // 正数，秒
        guard dt > 60 else { return nil }

        let firstGap = target - first.cellVoltage
        let lastGap = target - last.cellVoltage

        // 电压必须是在上升，且电压差必须是在收窄
        guard firstGap > lastGap, lastGap > 0.001 else { return nil }

        // 比值：这段里电压差缩窄了多少倍
        let ratio = firstGap / lastGap
        // ln(ratio) 是在 dt 时间内的"衰减指数"
        let decay = log(ratio)
        guard decay > 0.02 else { return nil }   // 电压几乎没动，算不了

        // 剩下的衰减量
        let remainDecay = log(lastGap / currentGap)
        guard remainDecay > 0 else { return 0 }

        let seconds = dt * remainDecay / decay
        // 上限 3 小时，防止算出离谱的值
        return min(seconds, 3 * 3600)
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
        return Result(remainingSeconds: seconds,
                      isEstimate: false,
                      note: "按剩余电量估算，留 10% 余量",
                      phase: nil)
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
