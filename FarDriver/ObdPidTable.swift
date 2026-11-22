//
//  ObdPidTable.swift
//  完整的 OBD2 PID 定义表（从 ymobd 反编译提取）
//
//  共 91 个 PID，每个都带名称、单位、数据长度、计算公式。
//

import Foundation

/// 一个 OBD2 PID 的完整定义
struct ObdPidDef: Identifiable {
    /// 命令字，如 "010C"
    let code: String
    /// 中文名
    let name: String
    /// 单位
    let unit: String
    /// 需要几个数据字节（1 或 2）
    let byteCount: Int
    /// 计算公式：输入前两个字节，返回数值
    let formula: (_ a: Double, _ b: Double) -> Double?

    var id: String { code }
    /// PID 字节（0x0C 这种）
    var pidByte: UInt8 {
        UInt8(code.suffix(2), radix: 16) ?? 0
    }
    /// 一个字节还是两个字节
    var isTwoByte: Bool { byteCount == 2 }
}

enum ObdPidTable {

    /// 所有 PID（按 code 排序）
    static let all: [ObdPidDef] = [
        ObdPidDef(code: "0100", name: "PID 支持情况（01-20）", unit: "", byteCount: 1,
                  formula: { a, b in nil }),
        ObdPidDef(code: "0101", name: "监控清除故障码后的状态", unit: "", byteCount: 1,
                  formula: { a, b in nil }),
        ObdPidDef(code: "0103", name: "燃油系统状态", unit: "", byteCount: 2,
                  formula: { a, b in nil }),
        ObdPidDef(code: "0104", name: "发动机负荷", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "0105", name: "冷却液温度", unit: "℃", byteCount: 1,
                  formula: { a, b in a - 40 }),
        ObdPidDef(code: "0106", name: "短期燃油修正（Bank 1）", unit: "%", byteCount: 1,
                  formula: { a, b in (a - 128) * 100.0 / 128.0 }),
        ObdPidDef(code: "0107", name: "长期燃油修正（Bank 1）", unit: "%", byteCount: 1,
                  formula: { a, b in (a - 128) * 100.0 / 128.0 }),
        ObdPidDef(code: "0108", name: "短期燃油修正（Bank 2）", unit: "%", byteCount: 1,
                  formula: { a, b in (a - 128) * 100.0 / 128.0 }),
        ObdPidDef(code: "0109", name: "长期燃油修正（Bank 2）", unit: "%", byteCount: 1,
                  formula: { a, b in (a - 128) * 100.0 / 128.0 }),
        ObdPidDef(code: "010A", name: "燃油压力(表压)", unit: "kPa", byteCount: 1,
                  formula: { a, b in a * 3 }),
        ObdPidDef(code: "010B", name: "进气歧管压力", unit: "kPa", byteCount: 1,
                  formula: { a, b in a }),
        ObdPidDef(code: "010C", name: "发动机转速", unit: "rpm", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 4.0 }),
        ObdPidDef(code: "010D", name: "车辆速度", unit: "km/h", byteCount: 1,
                  formula: { a, b in a }),
        ObdPidDef(code: "010E", name: "点火提前角", unit: "", byteCount: 1,
                  formula: { a, b in (a - 128) / 2.0 }),
        ObdPidDef(code: "010F", name: "进气温度", unit: "℃", byteCount: 1,
                  formula: { a, b in a - 40 }),
        ObdPidDef(code: "0110", name: "空气流量速率", unit: "g/s", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 100.0 }),
        ObdPidDef(code: "0111", name: "油门位置", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "0112", name: "空气状态", unit: "", byteCount: 1,
                  formula: { a, b in nil }),
        ObdPidDef(code: "0113", name: "氧传感器位置", unit: "", byteCount: 1,
                  formula: { a, b in nil }),
        ObdPidDef(code: "0114", name: "氧传感器（Bank 1，传感器1）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "0115", name: "氧传感器（Bank 1，传感器2）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "0116", name: "氧传感器（Bank 1，传感器3）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "0117", name: "氧传感器（Bank 1，传感器4）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "0118", name: "氧传感器（Bank 2，传感器1）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "0119", name: "氧传感器（Bank 2，传感器2）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "011A", name: "氧传感器（Bank 2，传感器3）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "011B", name: "氧传感器（Bank 2，传感器4）", unit: "V", byteCount: 2,
                  formula: { a, b in a / 200.0 }),
        ObdPidDef(code: "011D", name: "氧传感器存在情况", unit: "", byteCount: 1,
                  formula: { a, b in nil }),
        ObdPidDef(code: "011E", name: "动力输出状态", unit: "", byteCount: 1,
                  formula: { a, b in nil }),
        ObdPidDef(code: "011F", name: "发动机启动后运行时间", unit: "second", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0120", name: "PID 支持情况（21-40）", unit: "", byteCount: 1,
                  formula: { a, b in nil }),
        ObdPidDef(code: "0121", name: "故障指示灯点亮后行驶里程", unit: "km", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0122", name: "燃油压力（相对于歧管真空度）", unit: "kPa", byteCount: 2,
                  formula: { a, b in 0.079 * (256.0 * a + b) }),
        ObdPidDef(code: "0123", name: "燃油压力（柴油或汽油直喷）", unit: "kPa", byteCount: 2,
                  formula: { a, b in 10.0 * (256.0 * a + b) }),
        ObdPidDef(code: "0124", name: "当量比（Bank1，传感器1）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "0125", name: "当量比（Bank1，传感器2）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "0126", name: "当量比（Bank1，传感器3）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "0127", name: "当量比（Bank1，传感器4）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "0128", name: "当量比（Bank2，传感器1）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "0129", name: "当量比（Bank2，传感器2）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "012A", name: "当量比（Bank2，传感器3）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "012B", name: "当量比（Bank2，传感器4）", unit: "", byteCount: 1,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "012C", name: "废气循环", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "012D", name: "废气循环错误", unit: "%", byteCount: 1,
                  formula: { a, b in (a - 128) * 100.0 / 128.0 }),
        ObdPidDef(code: "012E", name: "蒸发净化命令", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "012F", name: "油量液位情况，剩余油量", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "0130", name: "故障码清除后热车次数", unit: "", byteCount: 1,
                  formula: { a, b in a - 40 }),
        ObdPidDef(code: "0131", name: "故障码清除后后行驶里程", unit: "km", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0132", name: "燃油蒸发系统蒸汽压力", unit: "Pa", byteCount: 2,
                  formula: { a, b in 0.5 * (256.0 * a + b) - 210.0 }),
        ObdPidDef(code: "0133", name: "大气压", unit: "kPa", byteCount: 1,
                  formula: { a, b in a }),
        ObdPidDef(code: "0134", name: "当量比（Bank 1，传感器1）", unit: "", byteCount: 1,
                  formula: { a, b in (a / 200.0) - 6.0 }),
        ObdPidDef(code: "0135", name: "当量比（Bank 1，传感器2）", unit: "", byteCount: 1,
                  formula: { a, b in (a / 200.0) - 6.0 }),
        ObdPidDef(code: "0136", name: "当量比（Bank 1，传感器3）", unit: "", byteCount: 1,
                  formula: { a, b in (a / 200.0) - 6.0 }),
        ObdPidDef(code: "0137", name: "当量比（Bank 1，传感器4）", unit: "", byteCount: 1,
                  formula: { a, b in (a / 200.0) - 6.0 }),
        ObdPidDef(code: "0139", name: "当量比（Bank 2，传感器2）", unit: "", byteCount: 1,
                  formula: { a, b in (a / 200.0) - 6.0 }),
        ObdPidDef(code: "013A", name: "当量比（Bank 2，传感器3）", unit: "", byteCount: 1,
                  formula: { a, b in (a / 200.0) - 6.0 }),
        ObdPidDef(code: "013B", name: "当量比（Bank 2，传感器4）", unit: "", byteCount: 1,
                  formula: { a, b in (a / 200.0) - 6.0 }),
        ObdPidDef(code: "013C", name: "催化剂温度（Bank 1，传感器1）", unit: "℃", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 10.0 - 40.0 }),
        ObdPidDef(code: "013D", name: "催化剂温度（Bank 2，传感器1）", unit: "℃", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 10.0 - 40.0 }),
        ObdPidDef(code: "013E", name: "催化剂温度（Bank 1，传感器2）", unit: "℃", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 10.0 - 40.0 }),
        ObdPidDef(code: "013F", name: "催化剂温度（Bank 2，传感器2）", unit: "℃", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 10.0 - 40.0 }),
        ObdPidDef(code: "0140", name: "PID 支持情况（41-60）", unit: "", byteCount: 1,
                  formula: { a, b in (256.0 * a + b) / 10.0 - 40.0 }),
        ObdPidDef(code: "0141", name: "这个驾驶周期的监控状态", unit: "", byteCount: 1,
                  formula: { a, b in (256.0 * a + b) / 10.0 - 40.0 }),
        ObdPidDef(code: "0142", name: "控制模块电压", unit: "V", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 1000.0 }),
        ObdPidDef(code: "0143", name: "绝对载荷", unit: "%", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0144", name: "等效比命令", unit: "", byteCount: 2,
                  formula: { a, b in 2.0 * (256.0 * a + b) / 65535.0 }),
        ObdPidDef(code: "0145", name: "相对节气门位置", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "0146", name: "环境空气温度", unit: "℃", byteCount: 1,
                  formula: { a, b in a - 40 }),
        ObdPidDef(code: "0147", name: "节气门位置绝对值B", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "0148", name: "节气门位置绝对值C", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "0149", name: "节气门位置绝对值D", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "014A", name: "节气门位置绝对值E", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "014B", name: "节气门位置绝对值F", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "014C", name: "油门执行器控制值", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "014D", name: "故障指示灯亮之后运行时间", unit: "minute", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "014E", name: "故障码清除后运行时间", unit: "minute", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "014F", name: "等效比最大值", unit: "", byteCount: 1,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0150", name: "空气流量传感器最大值", unit: "g/s", byteCount: 1,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0152", name: "乙醇百分比", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "0153", name: "蒸汽系统压力绝对值", unit: "Pa", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0154", name: "蒸汽系统压力", unit: "Pa", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0155", name: "短期二次氧传感器修正 Bank 1", unit: "%", byteCount: 2,
                  formula: { a, b in a * 50.0 - 50 * 1378.0 / 1000 }),
        ObdPidDef(code: "0156", name: "长期二次氧传感器修正 Bank 1", unit: "%", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0157", name: "短期二次氧传感器修正 Bank 2", unit: "%", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0158", name: "长期二次氧传感器修正 Bank 2", unit: "%", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "0159", name: "燃油压力（绝对压力）", unit: "kPa", byteCount: 2,
                  formula: { a, b in 256.0 * a + b }),
        ObdPidDef(code: "015A", name: "油门相对位置", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "015B", name: "混合动力电池剩余", unit: "%", byteCount: 1,
                  formula: { a, b in a * 100.0 / 255.0 }),
        ObdPidDef(code: "015C", name: "发动机机油温度", unit: "℃", byteCount: 1,
                  formula: { a, b in 256.0 * a + b - 40 }),
        ObdPidDef(code: "015D", name: "喷油正时", unit: "", byteCount: 2,
                  formula: { a, b in (256.0 * a + b) / 10.0 - 210.0 }),
        ObdPidDef(code: "015E", name: "引擎油量消耗速率", unit: "L/H", byteCount: 2,
                  formula: { a, b in 0.05 * (256.0 * a + b) }),
    ]

    /// 按 code 查定义
    static func def(_ code: String) -> ObdPidDef? {
        lookup[code.uppercased()]
    }

    private static let lookup: [String: ObdPidDef] = {
        var d: [String: ObdPidDef] = [:]
        for p in all { d[p.code] = p }
        return d
    }()
}
