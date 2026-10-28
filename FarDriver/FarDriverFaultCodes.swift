//
//  FarDriverFaultCodes.swift
//  远驱控制器故障码释义
//
//  ✅ 数据来源：远驱电控 App 2.2.7（正版）MotorNet6.dll 内的官方字符串表
//     提取位置：MotorNet6.dll 偏移 0x2A5F90 附近的资源区
//     官方原文顺序：
//       系统正常 / 1.电机霍尔故障 / 2.油门踏板故障 / 3.电流保护重启 /
//       4.相电流突变 / 5.过压故障 / 18.欠压故障 / 6.防盗报警 /
//       7.电机过温 / 8.控制器过温 / 9.相电流溢出 / 10.相线零点故障 /
//       17.缺相故障 / 11.相线短路故障 / 12.线电流零点故障 /
//       13.MOSFET上桥故障 / 14.MOSFET下桥故障 / 15.MOE电流保护 / 16.刹车故障
//
//  ⚠️ 关键点：第 0 项是「系统正常」，故障编号从 1 开始。
//     所以按位解析时 bit(编号) 对应故障，bit 0 不用（或表示正常）。
//     旧版把 bit 0 当成「控制器过流」，这是错的，会产生误报。
//

import Foundation

enum FarDriverFaultCodes {

    /// 官方故障表：编号 → 中文名
    /// 编号 0 表示正常，不出现在下面的列表里
    static let table: [Int: String] = [
        1:  "电机霍尔故障",
        2:  "油门踏板故障",
        3:  "电流保护重启",
        4:  "相电流突变",
        5:  "过压故障",
        6:  "防盗报警",
        7:  "电机过温",
        8:  "控制器过温",
        9:  "相电流溢出",
        10: "相线零点故障",
        11: "相线短路故障",
        12: "线电流零点故障",
        13: "MOSFET 上桥故障",
        14: "MOSFET 下桥故障",
        15: "MOE 电流保护",
        16: "刹车故障",
        17: "缺相故障",
        18: "欠压故障",
    ]

    /// 官方英文名（调试对照用）
    static let tableEN: [Int: String] = [
        1:  "Motor Hall Error",
        2:  "Throttle Error",
        3:  "Current Protect Restert",
        4:  "Phase Current Surge Protect",
        5:  "Over Voltage Alarm",
        6:  "Alarm Protect",
        7:  "Motor Temp Protect",
        8:  "Controller Temp Protect",
        9:  "Phase Current Overflow Protect",
        10: "Phase Zero Error",
        11: "Phase Short Alarm",
        12: "Line Current Zero Error",
        13: "MOSFET High Side Error",
        14: "MOSFET Low Side Error",
        15: "MOE Current Protect",
        16: "Brake Alarm",
        17: "Phase Lost Alarm",
        18: "Under Voltage Alarm",
    ]

    /// 按位解析：bit N == 1 表示「故障 N」
    /// - Parameter mask: 控制器上报的原始值
    /// - Returns: 用「、」连接的描述；无故障返回空字符串
    static func describe(bits mask: UInt16) -> String {
        guard mask != 0 else { return "" }
        var found: [String] = []
        // 编号 1...18（bit 0 是「系统正常」，不当作故障）
        for n in 1...18 where (mask & (1 << UInt16(n))) != 0 {
            if let t = table[n] { found.append(t) }
        }
        if found.isEmpty {
            // 只有 bit 0 置位，或者高位有未知位
            let unknown = UInt16(mask & ~UInt16(0x7FFFF)) // 19 位以上
            if unknown != 0 {
                return "未定义故障位(0x\(String(unknown, radix: 16, uppercase: true)))"
            }
            return ""
        }
        return found.joined(separator: "、")
    }

    /// 按编号解析：如果控制器上报的是「故障编号」而不是位掩码
    /// （例如直接给 7 表示电机过温），用这个
    static func describe(index n: Int) -> String {
        if n == 0 { return "" }
        return table[n] ?? "未定义故障(\(n))"
    }

    /// 按位解析：至少有一个明确的故障位
    static func hasFault(bits mask: UInt16) -> Bool {
        // 只看 bit 1...18，bit 0 不算故障
        return (mask & UInt16(0x7FFFE)) != 0
    }
}
