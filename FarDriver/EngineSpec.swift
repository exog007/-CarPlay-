//
//  EngineSpec.swift
//  发动机参数 —— 用于从「车速 + 转速」推算油耗
//
//  原理：
//    油耗 ≈ 每循环喷油量 × 转速 × 时间
//    每循环喷油量取决于：排量、缸数、进气效率（油门/负荷）
//    没有负荷数据时，用「转速/车速比」反推工况：
//      · 低速高档（转速低、车速高）→ 轻负荷 → 省油
//      · 低档高转（转速高、车速低）→ 重负荷 → 费油
//
//  参数在设置里按数据源单独配置，每套行程统计独立计算。
//

import Foundation

/// 每个行程账本的发动机参数
struct EngineSpec: Codable, Equatable {
    /// 气缸数
    var cylinders: Int = 4
    /// 排量（升）
    var displacement: Double = 2.0
    /// 是否带涡轮增压
    var turbo: Bool = false

    /// 常见缸数选项
    static let cylinderOptions: [Int] = [1, 2, 3, 4, 5, 6, 8, 10, 12]

    /// 默认参数
    static let `default` = EngineSpec()

    /// 每缸排量（升）
    var perCylinder: Double {
        guard cylinders > 0 else { return displacement }
        return displacement / Double(cylinders)
    }

    /// 进气形式描述
    var inductionLabel: String {
        turbo ? "涡轮增压" : "自然吸气"
    }

    /// 完整描述（设置页展示）
    var summary: String {
        String(format: "%d缸 %.1fL %@", cylinders, displacement, inductionLabel)
    }

    // MARK: - 油耗估算

    /// 根据车速和转速估算瞬时油耗（L/h）
    ///
    /// - Parameters:
    ///   - speedKmh: 车速
    ///   - rpm: 发动机转速
    /// - Returns: 估算油耗 L/h
    func fuelRate(speedKmh: Double, rpm: Double) -> Double {
        guard rpm > 0 else { return 0 }

        // ① 基础：怠速油耗
        //
        // 怠速时发动机维持最低转速，油耗和排量成正比。
        // 经验值：每升排量约 0.45 L/h（自然吸气），涡轮略高。
        let idleRate = displacement * (turbo ? 0.52 : 0.45)

        // 低转速（接近怠速）时直接用怠速油耗
        let idleRpm = 800.0
        if rpm <= idleRpm {
            return idleRate
        }

        // ② 每循环进气量估算
        //
        // 理论进气量 = 排量 × 转速/2（四冲程每两转一个循环）
        // 实际进气量 = 理论值 × 容积效率
        //
        // 容积效率随负荷变：怠速约 0.15，全负荷自然吸气约 0.85，
        // 涡轮增压全负荷可到 1.3。
        let rpmAboveIdle = rpm - idleRpm

        // ③ 从「转速/车速比」反推负荷
        //
        //   转速高但车速低 → 在低档位 → 负荷大
        //   转速低但车速高 → 在高档位 → 负荷小
        //
        // 用「每公里转数」(RPM per km/h) 作为负荷指标：
        //   正常行驶：约 30-60 RPM/(km/h)
        //   低档高转：>100
        //   高速巡航：<30
        let rpmPerKmh: Double
        if speedKmh >= 3 {
            rpmPerKmh = rpm / speedKmh
        } else {
            // 静止：按中等负荷算
            rpmPerKmh = 45
        }

        // 把 rpmPerKmh 映射到 0..1 的负荷系数
        //   25 → 0（最轻，高速巡航）
        //   90 → 1（最重，低档爬坡）
        let loadFactor = max(0, min(1, (rpmPerKmh - 25.0) / 65.0))

        // ④ 容积效率
        var ve = 0.15 + loadFactor * 0.70        // 自然吸气：0.15 ~ 0.85
        if turbo {
            ve = 0.15 + loadFactor * 1.15        // 涡轮：0.15 ~ 1.30
        }

        // ⑤ 转速越高，每循环效率略降（摩擦损失增加）
        let rpmPenalty = 1.0 + (rpmAboveIdle / 6000.0) * 0.15

        // ⑥ 每循环进气量（升）
        //   四冲程：每转进气 = 排量/2 × 容积效率
        let airPerRev = displacement / 2.0 * ve

        // ⑦ 空燃比 14.7:1（汽油）
        //   每升空气约 1.2 g，汽油密度 0.745 kg/L
        //
        //   每次进气（升）× 1.2 g/L ÷ 14.7 = 汽油克数
        //   ÷ 745 g/L = 汽油升数
        let fuelPerRev = airPerRev * 1.2 / 14.7 / 745.0

        // ⑧ 每秒转数 × 每次升数 × 3600 = L/h
        let revPerSec = rpm / 60.0
        let rate = revPerSec * fuelPerRev * 3600.0 * rpmPenalty

        // ⑨ 不低于怠速油耗
        return max(rate, idleRate)
    }

    /// 根据车速和转速估算瞬时百公里油耗（L/100km）
    ///
    /// - Returns: L/100km；车速太低时不计算（返回 0）
    func consumptionPer100km(speedKmh: Double, rpm: Double) -> Double {
        guard speedKmh >= 5 else { return 0 }
        let ratePerHour = fuelRate(speedKmh: speedKmh, rpm: rpm)     // L/h
        // L/h ÷ km/h × 100 = L/100km
        return ratePerHour / speedKmh * 100.0
    }

    // MARK: - 存取（按账本隔离）

    private static func key(_ l: TripLedger) -> String {
        "engineSpec.\(l.rawValue)"
    }

    static func load(_ l: TripLedger) -> EngineSpec {
        guard let data = UserDefaults.standard.data(forKey: key(l)),
              let spec = try? JSONDecoder().decode(EngineSpec.self, from: data) else {
            return .default
        }
        return spec
    }

    static func save(_ spec: EngineSpec, for l: TripLedger) {
        guard let data = try? JSONEncoder().encode(spec) else { return }
        UserDefaults.standard.set(data, forKey: key(l))
    }
}
