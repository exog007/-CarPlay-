//
//  ObdProtocol.swift
//  OBD2 / ELM327 协议层
//
//  ELM327 通过 BLE 串口（通常是 FFE0/FFE1 或 Nordic UART）通信：
//    发 AT 指令初始化 → 发 PID 查询 → 收到 "41 0C 1A F8" 这样的响应
//
//  支持的 PID 都是标准 SAE J1979 Mode 01：
//    0C  发动机转速    4 字节 → ((A*256)+B)/4
//    0D  车速          1 字节 → A km/h
//    05  水温          1 字节 → A-40 °C
//    0F  进气温度      1 字节 → A-40 °C
//    11  节气门开度    1 字节 → A*100/255 %
//    04  发动机负荷    1 字节 → A*100/255 %
//    42  电瓶电压      2 字节 → ((A*256)+B)/1000 V
//    2F  燃油液位      1 字节 → A*100/255 %
//    10  空气流量      2 字节 → ((A*256)+B)/100 g/s
//    5E  燃油消耗率    2 字节 → ((A*256)+B)/20 L/h
//
//  Mode 03 = 读故障码，Mode 04 = 清除故障码
//

import Foundation

/// 一条 OBD2 数据帧解析出来的字段（按 PID 分）
enum ObdPid: String, CaseIterable {
    case rpm        = "010C"   // 发动机转速
    case speed      = "010D"   // 车速
    case coolant    = "0105"   // 水温
    case intakeAir  = "010F"   // 进气温度
    case throttle   = "0111"   // 节气门
    case engineLoad = "0104"   // 发动机负荷
    case voltage    = "0142"   // 电瓶电压
    case fuelLevel  = "012F"   // 燃油液位
    case maf        = "0110"   // 空气流量
    case fuelRate   = "015E"   // 燃油消耗率（部分车不支持）
    case gear       = "01A4"   // 变速箱档位（大部分车不支持，支持就能读真实档位）

    /// 这个 PID 需要几个数据字节
    var byteCount: Int {
        switch self {
        case .rpm, .voltage, .maf, .fuelRate: return 2
        default: return 1
        }
    }

    /// 发出去的完整命令
    var command: String { rawValue }

    /// 响应里的 PID 字节（0x01 XX 中的第二个）
    var pidByte: UInt8 {
        UInt8(rawValue.suffix(2), radix: 16) ?? 0
    }
}

/// 一轮轮询拿到的原始值
struct ObdReading {
    var rpm: Double? = nil            // 转/分
    var speedKmh: Double? = nil       // km/h
    var coolantTemp: Double? = nil    // °C
    var intakeTemp: Double? = nil     // °C
    var throttle: Double? = nil       // 0~100 %
    var engineLoad: Double? = nil     // 0~100 %
    var batteryVoltage: Double? = nil // V
    var fuelLevel: Double? = nil      // 0~100 %
    var maf: Double? = nil            // g/s
    var fuelRate: Double? = nil       // L/h
    /// 变速箱档位原始值（PID 01A4，0 = 不支持/未知）
    var gear: Int? = nil
    var updatedAt: Date = Date()

    /// 有没有至少一项数据
    var hasAny: Bool {
        rpm != nil || speedKmh != nil || coolantTemp != nil || batteryVoltage != nil
    }

    /// 估算当前功率（kW）
    ///
    /// OBD2 不直接给功率。用「燃油消耗率 × 热值 × 效率」粗略估：
    ///   汽油热值约 8.9 kWh/L，柴油约 10.0，发动机热效率取 0.28
    /// 没有 fuelRate 时用「MAF 推算」：MAF/14.7 ≈ 燃油质量流量
    func estimatedPowerKW(isDiesel: Bool) -> Double? {
        let kwhPerL = isDiesel ? 10.0 : 8.9
        let eff = 0.28
        if let rate = fuelRate, rate > 0 {
            return rate * kwhPerL * eff          // L/h × kWh/L × 效率 = kW
        }
        if let maf = maf, maf > 0 {
            // MAF g/s → 燃油 L/h：质量流量 ÷ 空燃比 ÷ 汽油密度(745 g/L) × 3600
            let fuelGs = maf / 14.7
            let litresPerHour = fuelGs * 3600 / 745
            return litresPerHour * kwhPerL * eff
        }
        return nil
    }
}

// MARK: - 响应解析

enum ObdParser {

    /// 把字节还原成可读文本（调试日志用）
    ///
    /// 十六进制便于核对 PID 数据，同时附上可打印字符。
    static func debugText(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        let hex = bytes.prefix(24).map { String(format: "%02X", $0) }.joined()
        let ascii = String(bytes: bytes, encoding: .ascii)?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces) ?? ""
        if ascii.isEmpty { return hex }
        return "\(hex) | \(ascii)"
    }

    /// 把 ELM327 的字符串响应解析成字节数组
    ///
    /// 输入可能是：
    ///   "41 0C 1A F8 \r\r>"
    ///   "SEARCHING...\r41 0D 32 \r\r>"
    ///   "NO DATA\r\r>"
    ///   "7EA 04 41 0D 32 AA \r"   ← 多帧/带 CAN 头
    static func toBytes(_ raw: String) -> [UInt8]? {
        let cleaned = raw
            .replacingOccurrences(of: ">", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .uppercased()

        // 明确无数据
        if cleaned.contains("NO DATA") || cleaned.contains("UNABLE TO CONNECT") {
            return nil
        }

        // 找出所有两位十六进制
        var bytes: [UInt8] = []
        var token = ""
        for ch in cleaned {
            if ch.isHexDigit {
                token.append(ch)
                if token.count == 2 {
                    if let b = UInt8(token, radix: 16) { bytes.append(b) }
                    token = ""
                }
            } else {
                token = ""
            }
        }
        return bytes.isEmpty ? nil : bytes
    }

    /// 从字节里找「41 <pid> <数据...>」
    ///
    /// 初始化时已经发了 ATH0（关闭 CAN 头）和 ATS0（关闭空格），
    /// 所以标准响应就是干净的 `41 PID D1 D2`。
    /// 这里用滑动窗口找，容忍适配器偶尔带的多余字节。
    static func extract(_ bytes: [UInt8], pid: ObdPid) -> [UInt8]? {
        let target = pid.pidByte
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x41, bytes[i + 1] == target {
                let start = i + 2
                let n = pid.byteCount
                guard start + n <= bytes.count else { return nil }
                return Array(bytes[start..<(start + n)])
            }
            i += 1
        }
        return nil
    }

    /// 解析单个 PID 的数值
    static func value(_ bytes: [UInt8], pid: ObdPid) -> Double? {
        guard let d = extract(bytes, pid: pid), !d.isEmpty else { return nil }
        switch pid {
        case .rpm:
            guard d.count >= 2 else { return nil }
            return (Double(d[0]) * 256 + Double(d[1])) / 4.0
        case .speed:
            return Double(d[0])
        case .coolant, .intakeAir:
            return Double(d[0]) - 40.0
        case .throttle, .engineLoad, .fuelLevel:
            return Double(d[0]) * 100.0 / 255.0
        case .voltage:
            guard d.count >= 2 else { return nil }
            return (Double(d[0]) * 256 + Double(d[1])) / 1000.0
        case .maf:
            guard d.count >= 2 else { return nil }
            return (Double(d[0]) * 256 + Double(d[1])) / 100.0
        case .fuelRate:
            guard d.count >= 2 else { return nil }
            return (Double(d[0]) * 256 + Double(d[1])) / 20.0
        case .gear:
            return Double(d[0])
        }
    }

    /// 解析故障码（Mode 03）
    ///
    /// 响应形如：43 01 33 02 01 00 00 00 00
    /// 每两字节一个 DTC：第一位决定 P/C/B/U，后三位十六进制
    static func dtcList(_ bytes: [UInt8]) -> [String] {
        // 找到 0x43
        guard let start = bytes.firstIndex(of: 0x43) else { return [] }
        // 43 后面第一个字节是「有多少个码」（ISO 15765 里是帧数），有的适配器不带
        var idx = start + 1
        // 如果下一字节看起来像计数（> 0 且后面跟着成对数据），跳过它
        if idx < bytes.count, idx + 2 < bytes.count {
            let maybeCount = Int(bytes[idx])
            let remaining = bytes.count - idx - 1
            if maybeCount > 0 && remaining >= maybeCount * 2 {
                idx += 1
            }
        }

        var out: [String] = []
        while idx + 1 < bytes.count {
            let a = bytes[idx], b = bytes[idx + 1]
            idx += 2
            // 0000 表示无更多故障码
            if a == 0 && b == 0 { continue }
            let letter: Character
            switch (a & 0xC0) >> 6 {
            case 0:  letter = "P"
            case 1:  letter = "C"
            case 2:  letter = "B"
            default: letter = "U"
            }
            let d1 = (a & 0x30) >> 4
            let d2 = a & 0x0F
            out.append(String(format: "%@%X%X%02X", String(letter), d1, d2, b))
        }
        return out
    }
}

// MARK: - DTC 中文说明（常见码）

enum ObdDtcText {

    static func describe(_ code: String) -> String {
        switch code {
        case "P0100": return "空气流量计电路故障"
        case "P0101": return "空气流量计范围异常"
        case "P0110": return "进气温度传感器故障"
        case "P0115": return "水温传感器故障"
        case "P0117": return "水温传感器电压低"
        case "P0118": return "水温传感器电压高"
        case "P0120": return "节气门位置传感器故障"
        case "P0130": return "氧传感器故障（B1S1）"
        case "P0135": return "氧传感器加热器故障"
        case "P0171": return "混合气过稀"
        case "P0172": return "混合气过浓"
        case "P0200": return "喷油嘴电路故障"
        case "P0300": return "多缸失火"
        case "P0301": return "第 1 缸失火"
        case "P0302": return "第 2 缸失火"
        case "P0303": return "第 3 缸失火"
        case "P0304": return "第 4 缸失火"
        case "P0335": return "曲轴位置传感器故障"
        case "P0340": return "凸轮轴位置传感器故障"
        case "P0401": return "EGR 流量不足"
        case "P0420": return "三元催化效率低"
        case "P0442": return "燃油蒸发系统小泄漏"
        case "P0455": return "燃油蒸发系统大泄漏"
        case "P0500": return "车速传感器故障"
        case "P0505": return "怠速控制故障"
        case "P0560": return "电瓶电压异常"
        case "P0600": return "通信总线故障"
        case "P0606": return "发动机控制模块故障"
        case "P0700": return "变速箱控制系统故障"
        case "P1000": return "未完成自检（OBD 就绪状态）"
        case "P1101": return "进气流量异常"
        case "P2101": return "节气门执行器故障"
        case "P2135": return "节气门位置传感器不一致"
        default: break
        }

        // 按首位给个粗略分类
        if code.hasPrefix("P0") { return "动力系统故障" }
        if code.hasPrefix("B") { return "车身系统故障" }
        if code.hasPrefix("C") { return "底盘系统故障" }
        if code.hasPrefix("U") { return "网络通信故障" }
        return "未知故障"
    }
}

// MARK: - 档位

/// 自动挡档位 + 手动模式档位
///
/// 显示规则：
///   自动：P / R / N / D 单选高亮
///   手动：M 高亮，同时 1~5 中当前档位高亮（只显示一位数字）
enum ObdGear: Hashable {
    case park         // P
    case reverse      // R
    case neutral      // N
    case drive        // D
    /// 手动模式的第 n 档（1~5）
    case manual(Int)
    case unknown

    /// 单选高亮用：手动档都归到 .manual(n) 这一格
    var label: String {
        switch self {
        case .park:    return "P"
        case .reverse: return "R"
        case .neutral: return "N"
        case .drive:   return "D"
        case .manual:  return "M"
        case .unknown: return "－"
        }
    }

    /// 是不是手动模式
    var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    /// 手动档位数字（1~5），非手动返回 nil
    var manualNumber: Int? {
        if case .manual(let n) = self { return n }
        return nil
    }

    /// 按 PID 01A4 的原始字节解码
    ///
    /// PID A4 的取值各家车厂不统一（SAE 只规定 0 = 不支持）。
    /// 常见约定（都试一遍）：
    ///   · 1=P, 2=R, 3=N, 4=D, 5~9 = 手动 1~5 档
    ///   · 0x10=P, 0x20=R, 0x30=N, 0x40=D，0x51~0x55 = 手动 1~5
    ///   · 0x01~0x08 = 前进 1~8 档（手动挡车）
    static func decode(_ raw: Int) -> ObdGear {
        guard raw > 0 else { return .unknown }

        // ── 常见直接编码 ──
        switch raw {
        case 1:  return .park
        case 2:  return .reverse
        case 3:  return .neutral
        case 4:  return .drive
        case 5...9: return .manual(raw - 4)      // 5 → 1挡, 6 → 2挡 ...
        default: break
        }

        // ── 带进位编码：0x10=P 0x20=R 0x30=N 0x40=D 0x51~0x55=手动 ──
        let high = (raw >> 4) & 0x0F
        let low  = raw & 0x0F
        switch high {
        case 1: return .park
        case 2: return .reverse
        case 3: return .neutral
        case 4: return .drive
        case 5: return low >= 1 && low <= 8 ? .manual(low) : .unknown
        default: break
        }

        // ── 只给低 4 位的情况 ──
        switch low {
        case 1:  return .park
        case 2:  return .reverse
        case 3:  return .neutral
        case 4:  return .drive
        case 5...9: return .manual(low - 4)
        default: break
        }

        // ── 0x11~0x18 视为前进 1~8 档（有些手动挡车这么编码）──
        if raw >= 0x11 && raw <= 0x18 {
            return .manual(raw - 0x10)
        }

        return .unknown
    }
}
