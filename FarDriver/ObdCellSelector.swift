//
//  ObdCellSelector.swift
//  按车实际支持的能力，决定竞技仪表底部显示哪几格
//
//  汽车有十几个常用发动机参数，摩托车往往只有 3~4 个。
//  写死会让满屏 «—»，所以这里动态挑选：
//    · 优先显示有数据的
//    · 数据不足时用转速/车速补充
//    · 保证整行铺满，不留空洞
//

import Foundation

/// 竞技仪表底部的一格
struct ObdDashCell: Identifiable, Equatable {
    enum Kind: String {
        // ── 基础 ──
        case voltage        // 电瓶电压
        case coolant        // 水温
        case intake         // 进气温度
        case throttle       // 节气门
        case load           // 负荷
        case fuelLevel      // 燃油液位

        // ── 发动机参数 ──
        case map            // 进气歧管压力
        case stft           // 短期燃油修正
        case ltft           // 长期燃油修正
        case timing         // 点火提前角
        case maf            // 空气流量
        case fuelRate       // 燃油消耗率
        case o2voltage      // 前氧传感器电压
        case o2trim         // 前氧传感器修正
        case baro           // 大气压
        case runTime        // 启动后运行时间
        case fuelPressure   // 燃油压力

        // ── 补充位 ──
        case rpm            // 转速
        case speed          // 车速
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
    ///
    /// - Parameters:
    ///   - available: 已经读到数据的参数集合
    ///   - maxCells: 最多显示几格（横屏一般 6 格）
    /// - Returns: 填满的顺序列表
    static func pick(available: Set<ObdDashCell.Kind>, maxCells: Int) -> [ObdDashCell.Kind] {

        // 优先级：越靠前越重要
        let priority: [ObdDashCell.Kind] = [
            .coolant,       // 水温最常看
            .voltage,       // 电瓶
            .load,          // 负荷
            .throttle,      // 节气门
            .map,           // 进气压力
            .intake,        // 进气温度
            .timing,        // 点火提前角
            .stft,          // 短期修正
            .ltft,          // 长期修正
            .maf,           // 空气流量
            .o2voltage,     // 氧传感器
            .o2trim,        // 氧传感器修正
            .fuelPressure,  // 燃油压力
            .fuelRate,      // 油耗率
            .fuelLevel,     // 油位
            .baro,          // 大气压
            .runTime,       // 运行时间
        ]

        var result = priority.filter { available.contains($0) }

        // 不够就用转速/车速补充（避免整行半空）
        let fillers: [ObdDashCell.Kind] = [.rpm, .speed]
        var i = 0
        while result.count < maxCells {
            result.append(fillers[i % fillers.count])
            i += 1
            if i > maxCells * 2 { break }
        }

        return Array(result.prefix(maxCells))
    }
}
