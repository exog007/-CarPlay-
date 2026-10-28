//
//  FarDriverFaultCodes.swift
//  远驱控制器故障码释义
//
//  ⚠️ 注意：远驱官方没有公开完整的故障位定义
//     这里的位定义来自社区资料 + 常见车规故障，标注了可信度
//     如果实际显示对不上，把老版本 App 显示的故障码发我，我来校正
//

import Foundation

enum FarDriverFaultCodes {

    /// 常见的远驱故障位（bit 索引 → 描述）
    /// confidence: 可靠性标记，true = 社区验证过，false = 推测
    static let bits: [(bit: Int, text: String, confidence: Bool)] = [
        (0,  "控制器过流", true),
        (1,  "控制器过温", true),
        (2,  "电机过温", true),
        (3,  "电池电压过低", true),
        (4,  "电池电压过高", true),
        (5,  "转把/油门故障", true),
        (6,  "刹把故障", false),
        (7,  "霍尔故障", true),
        (8,  "相线短路", true),
        (9,  "电机缺相", false),
        (10, "MOS 管故障", false),
        (11, "过载保护", false),
        (12, "控制器通讯故障", false),
        (13, "防盗触发", false),
        (14, "电机缺相", false),
        (15, "控制器内部故障", false),
    ]

    /// 把位掩码翻译成人话
    /// - Parameter bits: 原始故障码
    /// - Returns: 用「、」连接的描述；无故障返回空字符串
    static func describe(bits mask: UInt16) -> String {
        guard mask != 0 else { return "" }
        var found: [String] = []
        for entry in self.bits where (mask & (1 << UInt16(entry.bit))) != 0 {
            found.append(entry.text)
        }
        if found.isEmpty {
            // 有值但没匹配到已知位
            return "未知故障(0x\(String(mask, radix: 16, uppercase: true)))"
        }
        return found.joined(separator: "、")
    }

    /// 故障码是否可疑（推测的位）
    static func isUncertain(_ bitIndex: Int) -> Bool {
        guard let e = bits.first(where: { $0.bit == bitIndex }) else { return true }
        return !e.confidence
    }
}
