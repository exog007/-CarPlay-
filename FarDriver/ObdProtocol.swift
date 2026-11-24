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

    // ── 发动机参数 ──
    case manifoldPressure = "010B"   // 进气歧管绝对压力 kPa
    case shortFuelTrim    = "0106"   // 短期燃油修正 %
    case longFuelTrim     = "0107"   // 长期燃油修正 %
    case timingAdvance    = "010E"   // 点火提前角 °
    case o2Sensor1        = "0114"   // 氧传感器 1（电压 + 修正）
    case fuelPressure     = "010A"   // 燃油压力 kPa
    case baroPressure     = "0133"   // 大气压 kPa
    case runtime          = "011F"   // 启动后运行时间 秒

    /// 这个 PID 需要几个数据字节
    var byteCount: Int {
        switch self {
        case .rpm, .voltage, .maf, .fuelRate: return 2
        case .o2Sensor1: return 4          // 0114 返回 4 字节（电压2 + 修正2）
        case .runtime: return 2
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

    // ── 发动机参数（PID 0B / 06 / 07 / 0E / 14 / 0A / 33）──
    /// 进气歧管绝对压力 kPa（PID 010B）
    var manifoldPressure: Double? = nil
    /// 短期燃油修正 %（PID 0106，-100~100）
    var shortFuelTrim: Double? = nil
    /// 长期燃油修正 %（PID 0107，-100~100）
    var longFuelTrim: Double? = nil
    /// 点火提前角 °（PID 010E）
    var timingAdvance: Double? = nil
    /// 氧传感器 1 电压 V（PID 0114）
    var o2Voltage: Double? = nil
    /// 氧传感器 1 修正 %（PID 0114 后两字节，有些车不给）
    var o2Trim: Double? = nil
    /// 燃油压力 kPa（PID 010A）
    var fuelPressure: Double? = nil
    /// 大气压 kPa（PID 0133）
    var barometricPressure: Double? = nil
    /// 发动机启动后运行时间 秒（PID 011F）
    var runTime: Double? = nil

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
        let ascii = rawString(bytes)
        if ascii.isEmpty { return hex }
        return "\(hex) | \(ascii)"
    }

    /// 只取可打印字符（去掉控制符）
    static func rawString(_ bytes: [UInt8]) -> String {
        let s = String(bytes: bytes, encoding: .ascii)?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ">", with: " ")
            .trimmingCharacters(in: .whitespaces) ?? ""
        // 去掉残留控制字符
        return s.filter { $0.isLetter || $0.isNumber || $0.isWhitespace
                          || ".,:;()-/?".contains($0) }
                .trimmingCharacters(in: .whitespaces)
    }

    /// 把 ELM327 的字符串响应解析成字节数组
    ///
    /// ⚠️ 关键：CAN 头（7E8 / 7E9 / 7DF…）是 **3 位**十六进制，
    /// 不能简单按 2 字符切，否则 "7E8 04 41 0C 1A F8" 会解析成
    /// 7E 80 44 14 10 C1 AF 8 —— 全部错位。
    ///
    /// 这里的做法：按「空白」分词，再判断每个词：
    ///   · 3 位 → 是 CAN 头，丢弃
    ///   · 2 位 → 是数据字节
    ///   · 其它（如 10 14 这种）→ 按 2 位切分
    static func toBytes(_ raw: String) -> [UInt8]? {
        let cleaned = raw
            .replacingOccurrences(of: ">", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .uppercased()

        if cleaned.contains("NO DATA") || cleaned.contains("UNABLE TO CONNECT") {
            return nil
        }

        var bytes: [UInt8] = []

        // 按空白分词
        let tokens = cleaned.split { $0 == " " || $0 == "\t" }

        for token in tokens {
            let word = String(token)
            // 只处理纯十六进制的词
            guard !word.isEmpty, word.allSatisfy({ $0.isHexDigit }) else { continue }

            switch word.count {
            case 3:
                // CAN 头（7E8 / 7E9 / 7DF…），丢弃
                continue
            case 2:
                if let b = UInt8(word, radix: 16) { bytes.append(b) }
            case 1:
                // 单个字符，跳过（可能是残留）
                continue
            default:
                // 更长的词：可能是多个字节粘连，也可能混了 CAN 头
                //
                // BLE 分包会产生这种情况（实测）：
                //   "7E8064100BE3FA817E9064100981E801"
                //   前半是 7E8 帧，后半 "7E9064..." 里的 7E9 是第二个 ECU 的头
                //
                // 处理：逐字符扫描，识别并跳过 3 位 CAN 头（7E0~7EF / 7DF）
                var i = word.startIndex
                while i < word.endIndex {
                    // 优先匹配 3 位 CAN 头（7E0~7EF / 7DF）
                    if word[i] == "7" {
                        let threeEnd = word.index(i, offsetBy: 3, limitedBy: word.endIndex) ?? word.endIndex
                        if word.distance(from: i, to: threeEnd) == 3 {
                            let head = String(word[i..<threeEnd])
                            // 用 Int 比较，避免超出 UInt8 范围
                            if let hv = Int(head, radix: 16),
                               (0x7E0...0x7EF).contains(hv) || hv == 0x7DF {
                                i = threeEnd
                                continue
                            }
                        }
                    }
                    // 普通 2 位数据
                    let twoEnd = word.index(i, offsetBy: 2, limitedBy: word.endIndex) ?? word.endIndex
                    let chunk = String(word[i..<twoEnd])
                    if chunk.count == 2, let b = UInt8(chunk, radix: 16) {
                        bytes.append(b)
                    }
                    i = twoEnd
                }
            }
        }
        return bytes.isEmpty ? nil : bytes
    }

    /// 从字节里找「41 <pid> <数据...>」
    ///
    /// 现在保持 CAN 头开启（ATH1），响应形如：
    ///   7E8 04 41 0C 1A F8
    /// 经过 toBytes 后 CAN 头已丢弃，剩下 [04, 41, 0C, 1A, F8]，
    /// 其中 04 是 ISO-TP 的长度字节（单帧 SF）。
    ///
    /// 这里用滑动窗口找 `41 PID`，能自动跳过长度字节和任何多余内容。
    static func extract(_ bytes: [UInt8], pid: ObdPid) -> [UInt8]? {
        let target = pid.pidByte
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x41, bytes[i + 1] == target {
                let start = i + 2
                let n = pid.byteCount
                guard start + n <= bytes.count else { return nil }
                let result = Array(bytes[start..<(start + n)])
                // 全 0 通常表示无效响应（车速 0 是合法的，所以排除 speed）
                if result.allSatisfy({ $0 == 0 }) && pid != .speed { return nil }
                return result
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

        // ── 发动机参数 ──
        case .manifoldPressure:
            return Double(d[0])
        case .shortFuelTrim, .longFuelTrim:
            return (Double(d[0]) - 128.0) * 100.0 / 128.0
        case .timingAdvance:
            return Double(d[0]) / 2.0 - 64.0
        case .o2Sensor1:
            // 0114 返回 4 字节：电压(2) + 修正(2)
            // 这里主值取电压
            guard d.count >= 2 else { return nil }
            return Double(d[0]) / 200.0
        case .fuelPressure:
            return Double(d[0]) * 3.0
        case .baroPressure:
            return Double(d[0])
        case .runtime:
            guard d.count >= 2 else { return nil }
            return Double(d[0]) * 256.0 + Double(d[1])
        }
    }

    /// 解析氧传感器 1 的修正值（0114 后两字节）
    static func o2Trim(_ bytes: [UInt8]) -> Double? {
        guard let d = extract(bytes, pid: .o2Sensor1) else { return nil }
        // extract 只取 byteCount 个字节，这里手动找 41 14 后的第 3、4 字节
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x41, bytes[i + 1] == 0x14 {
                let start = i + 4      // 跳过 41 14 + 电压2字节
                guard start + 2 <= bytes.count else { return nil }
                return 100.0 * Double(bytes[start]) / 128.0 - 100.0
            }
            i += 1
        }
        return nil
    }


    /// 通用故障码解析：自动识别 Mode 03 / 07 / 0A 的响应
    ///
    /// 响应首字节：
    ///   0x43 = Mode 03 已存储故障码
    ///   0x47 = Mode 07 待定故障码
    ///   0x4A = Mode 0A 永久故障码
    /// 之后是若干对字节，每对表示一个 DTC，00 00 表示结束。
    static func dtcListPlain(_ bytes: [UInt8]) -> [String] {
        // 同时兼容三种响应格式（已用真实数据验证 8/9 用例）：
        //
        //   ① 标准 ELM327（ATH0）：  43 01 33 02 01 00 00
        //   ② CAN ISO-TP（ATH1）：   [PCI] 43 01 33 02 01 00
        //       toBytes 剥掉 CAN 头后剩 "06 43 01 33 02 01 00"，06 是 PCI
        //   ③ ymobd 变体：可能带计数器前缀
        //
        // 处理步骤：
        //   1. 找到响应码 43 / 47 / 4A
        //   2. 判断前面是不是 ISO-TP PCI，是就按声明长度截断
        //   3. 判断剩余部分首字节是不是计数器，是就跳过
        //   4. 两字节一个 DTC，遇 00 00 结束

        let markers: [UInt8] = [0x43, 0x47, 0x4A]
        guard let start = bytes.firstIndex(where: { markers.contains($0) }) else {
            return []
        }

        var rest = Array(bytes[(start + 1)...])

        // ── ① ISO-TP PCI 处理 ──
        // PCI 在响应码前一个字节：高 4 位 = 0，低 4 位 = 数据长度（含响应码）
        if start >= 1 {
            let pci = bytes[start - 1]
            let declared = Int(pci & 0x0F)
            let actual = bytes.count - start
            if (pci & 0xF0) == 0x00, declared >= 1, declared <= 8, declared <= actual {
                rest = Array(rest.prefix(max(0, declared - 1)))
            }
        }

        // ── ② 计数器处理 ──
        // 条件：剩余长度是奇数，且首字节正好等于「剩余对数」
        if rest.count >= 3, rest.count % 2 == 1 {
            let cnt = Int(rest[0])
            if cnt >= 1, cnt <= 20, rest.count == cnt * 2 + 1 {
                rest.removeFirst()
            }
        }

        // ── ③ 两字节解析 ──
        var out: [String] = []
        var i = 0
        while i + 1 < rest.count {
            let a = rest[i], b = rest[i + 1]
            i += 2
            // 00 00 = 列表结束
            if a == 0 && b == 0 { break }
            // 填充值
            if a == 0xFF && b == 0xFF { continue }
            if a == 0xAA && b == 0xAA { continue }

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
    ///   · 0x0E = P（某些车型）, 0x0D = R, 0x0C = N, 0x0B = D
    static func decode(_ raw: Int) -> ObdGear {
        guard raw > 0 else { return .unknown }

        // ── 常见直接编码 ──
        switch raw {
        case 1:  return .park
        case 2:  return .reverse
        case 3:  return .neutral
        case 4:  return .drive
        case 5...9: return .manual(raw - 4)
        default: break
        }

        // ── 另一种常见：P=0x0E, R=0x0D, N=0x0C, D=0x0B ──
        switch raw {
        case 0x0E: return .park
        case 0x0D: return .reverse
        case 0x0C: return .neutral
        case 0x0B: return .drive
        default: break
        }

        // ── 带进位编码：0x10=P 0x20=R 0x30=N 0x40=D 0x51~0x58=手动 ──
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

        // ── 0x11~0x18 视为前进 1~8 档 ──
        if raw >= 0x11 && raw <= 0x18 {
            return .manual(raw - 0x10)
        }

        return .unknown
    }
}
