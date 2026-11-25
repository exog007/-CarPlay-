//
//  ObdFullPidSet.swift
//  全部可读 OBD PID 集合
//
//  ObdPid 枚举只覆盖了仪表要用的十来个，
//  而 ObdPidTable 里有 91 个完整定义。
//  这里提供「按 code 字符串操作」的补充接口，
//  让轮询能覆盖所有能读的 PID。
//

import Foundation

extension ObdManager {

    /// 仪表六格 + 大数字要用的 code（永远优先轮询）
    /// 竞技仪表要用的 7 项（顺序和仪表底部六格一致）
    ///
    ///   转速 | 车速 | 电压 | 水温 | 进气 | 节气门 | 怠速油耗
    static let dashCodes: [String] = [
        "010C",   // 转速（大数字）
        "010D",   // 车速（大数字）
        "0142",   // 电压
        "0105",   // 水温
        "010F",   // 进气温度
        "0111",   // 节气门
        "015E",   // 怠速油耗
        "010E",   // 点火提前角（摩托车用这个替代负荷）
    ]

    /// 摩托车仪表要用的（负荷换成点火提前角）
    static var motorcycleDashCodes: [String] {
        // 摩托不要负荷，加上点火提前角
        dashCodes.filter { $0 != "0104" }
    }

    /// 全部可读 PID 的 code 列表（按优先级排序）
    ///
    /// 顺序：
    ///   ① 仪表用的（最快看到数据）
    ///   ② 常用发动机参数
    ///   ③ 其余（O2、燃油修正、里程等）
    static var allReadableCodes: [String] {
        let table = ObdPidTable.all.map { $0.code }

        // 常用参数优先
        let hot: [String] = [
            "010B",   // 进气歧管压力
            "0106",   // 短期燃油修正
            "0107",   // 长期燃油修正
            "010E",   // 点火提前角
            "010A",   // 燃油压力
            "0133",   // 大气压
            "011F",   // 启动后运行时间
            "012F",   // 燃油液位
            "0110",   // 空气流量
            "0114",   // 氧传感器 1
            "0101",   // 就绪状态
            "011C",   // OBD 标准
            "0131",   // 清除码后里程
            "0142",   // 电压
        ]

        var seen = Set<String>()
        var out: [String] = []

        for c in dashCodes + hot + table {
            let key = c.uppercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(key)
        }
        return out
    }

    /// 从位图里解析出「车支持的全部 code」
    ///
    /// 和 built-in 的 supportedPids 不同，这里返回字符串 code，
    /// 能覆盖 ObdPidTable 里的所有 PID。
    static func parseSupportedCodes(_ bytes: [UInt8]) -> Set<String> {
        var out = Set<String>()
        var i = 0
        while i + 5 < bytes.count {
            guard bytes[i] == 0x41 else { i += 1; continue }
            let pidBase = Int(bytes[i + 1])
            let map = Array(bytes[(i + 2)..<(i + 6)])
            for (byteIdx, b) in map.enumerated() {
                for bit in 0..<8 where (b & (0x80 >> bit)) != 0 {
                    let pidNum = pidBase + 1 + byteIdx * 8 + bit
                    if pidNum <= 0xFF {
                        out.insert(String(format: "01%02X", pidNum))
                    }
                }
            }
            i += 6
        }
        return out
    }
}
