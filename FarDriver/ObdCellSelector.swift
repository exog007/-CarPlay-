//
//  ObdCellSelector.swift
//  按车实际支持的能力，决定竞技仪表底部显示哪几格
//
//  汽车有 6 个常用指标，摩托车往往只有 3~4 个。
//  写死 6 格会让摩托车满屏 «—»，所以这里动态挑选：
//    · 优先显示有数据的
//    · 数据不足时用转速/车速补充
//    · 保证整行铺满，不留空洞
//

import Foundation

/// 竞技仪表底部的一格
struct ObdDashCell: Identifiable, Equatable {
    enum Kind: String {
        case voltage      // 电瓶电压
        case coolant      // 水温
        case intake       // 进气温度
        case throttle     // 节气门
        case load         // 负荷
        case fuelLevel    // 燃油液位
        case rpm          // 转速（补位用）
        case speed        // 车速（补位用）
        case maf          // 空气流量
        case fuelRate     // 燃油消耗率
        case runTime      // 启动后运行时间
        case baro         // 大气压
    }

    let kind: Kind
    let title: String
    let value: String
    let unit: String
    /// 是否处于告警状态（红字）
    let isAlert: Bool

    var id: String { kind.rawValue }
}

enum ObdCellSelector {

    /// 挑选要显示的格子
    /// - Parameters:
    ///   - hasCoolant: 有水温数据
    ///   - hasIntake: 有进气温度
    ///   - hasThrottle: 有节气门
    ///   - hasLoad: 有负荷
    ///   - hasFuel: 有燃油液位
    ///   - hasVoltage: 有电压
    ///   - maxCells: 最多显示几格（横屏一般 6 格）
    /// - Returns: 填满的顺序列表
    static func pick(maxCells: Int,
                     hasVoltage: Bool,
                     hasCoolant: Bool,
                     hasIntake: Bool,
                     hasThrottle: Bool,
                     hasLoad: Bool,
                     hasFuel: Bool) -> [ObdDashCell.Kind] {

        // 优先级顺序：最常看的排前面
        var candidates: [ObdDashCell.Kind] = []

        if hasCoolant  { candidates.append(.coolant) }
        if hasVoltage  { candidates.append(.voltage) }
        if hasThrottle { candidates.append(.throttle) }
        if hasLoad     { candidates.append(.load) }
        if hasIntake   { candidates.append(.intake) }
        if hasFuel     { candidates.append(.fuelLevel) }

        // 不够就用转速/车速轮换补位（避免整行半空）
        let fillers: [ObdDashCell.Kind] = [.rpm, .speed]
        var i = 0
        while candidates.count < maxCells {
            candidates.append(fillers[i % fillers.count])
            i += 1
            // 防止无限循环
            if i > maxCells * 2 { break }
        }

        return Array(candidates.prefix(maxCells))
    }
}
