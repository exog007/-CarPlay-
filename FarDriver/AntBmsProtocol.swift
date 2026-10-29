//
//  AntBmsProtocol.swift
//  蚂蚁 BMS（ANT-BMS）蓝牙协议
//
//  协议来源：社区开源实现 syssi/esphome-ant-bms（已支持十几种蚂蚁型号）
//            https://github.com/syssi/esphome-ant-bms
//
//  ⚠️ 通用设计：串数不写死，从状态帧里读出来。
//     8 串 / 16 串 / 21 串 / 24 串 / 32 串都走同一套。
//
//  ── 连接参数 ──
//    服务 UUID : 0000FFE0
//    特征 UUID : 0000FFE1
//    写入方式 : 不需要响应（Write Without Response）
//
//  ── 请求帧（固定 10 字节）──
//    [0] 0x7E              帧头1
//    [1] 0xA1              帧头2
//    [2] function          功能码
//    [3] address 低字节
//    [4] address 高字节
//    [5] value
//    [6] CRC 低
//    [7] CRC 高            CRC16 从 [1] 起算 5 字节
//    [8] 0xAA              帧尾1
//    [9] 0x55              帧尾2
//
//  ── 响应帧 ──
//    7E A1 <功能码> ... <数据> <CRC 2字节> AA 55
//    最小 10 字节，最大 192 字节
//

import Foundation
import CoreBluetooth

// MARK: - 常量

enum AntBmsBLE {
    static let serviceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    static let characteristicUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
}

enum AntFrame {
    static let start1: UInt8 = 0x7E
    static let start2: UInt8 = 0xA1
    static let end1:   UInt8 = 0xAA
    static let end2:   UInt8 = 0x55

    // 功能码
    static let status:      UInt8 = 0x01   // 读状态
    static let deviceInfo:  UInt8 = 0x02   // 读设备信息

    // 响应帧里的类型
    static let typeStatus:     UInt8 = 0x11
    static let typeDeviceInfo: UInt8 = 0x12
    static let typeSystemLog:  UInt8 = 0x13
    static let typePermission: UInt8 = 0x14
    static let typeSystemInfo: UInt8 = 0x15
    static let typeGps:        UInt8 = 0x16
}

// MARK: - 数据模型

struct AntBmsData: Equatable {
    var totalVoltage: Double = 0        // 总电压 V
    var current: Double = 0             // 电流 A，负=放电 正=充电
    var power: Double { totalVoltage * current }
    var soc: Int = 0                    // 剩余电量 %
    var capacityRemaining: Double = 0   // 剩余容量 Ah
    var capacityTotal: Double = 0       // 设计容量 Ah
    var cycles: Int = 0                 // 循环次数（= 累计循环容量 ÷ 额定容量）
    var totalCycleCapacity: Double = 0  // 累计循环容量 Ah（BMS 原始值）
    var bmsSoh: Int = 0                 // BMS 自己算的健康度 %（仅参考）
    var cellCount: Int = 0              // 串数（BMS 自己报告）
    var cells: [Double] = []            // 单体电压 V，长度 = cellCount
    var temps: [Int] = []               // 温度 °C
    var mosTemp: Int = 0
    var balancing: [Bool] = []          // 每节是否在均衡
    var protectionStatus: UInt32 = 0
    var isCharging = false
    var isDischarging = false
    var balancingActive = false
    var updatedAt: Date = Date()

    // BMS 自己算好的极值（比 App 算的更准）
    var maxCellFromBms: Double = 0
    var minCellFromBms: Double = 0
    var maxCellIndexFromBms: Int = 0
    var minCellIndexFromBms: Int = 0

    // ── BMS 自己算好的剩余时间（分钟）──
    // 官方 App 直接显示这两个值，比按电流估算准
    var chargeRemainMin: Int = 0
    var dischargeRemainMin: Int = 0
    // 电池类型：0xFAF1=三元锂 0xFAF2=磷酸铁锂 0xFAF3=钛酸锂
    var chemistryCode: Int = 0

    /// 电池类型名
    var chemistryName: String {
        switch chemistryCode {
        case 0xFAF1: return "三元锂"
        case 0xFAF2: return "磷酸铁锂"
        case 0xFAF3: return "钛酸锂"
        case 0xFAF4: return "自定义"
        default:     return chemistryCode == 0 ? "未知" : String(format: "0x%04X", chemistryCode)
        }
    }

    /// 最高单体
    var maxCell: Double { cells.max() ?? 0 }
    var minCell: Double { cells.min() ?? 0 }
    var maxCellIndex: Int { cells.firstIndex(of: maxCell).map { $0 + 1 } ?? 0 }
    var minCellIndex: Int { cells.firstIndex(of: minCell).map { $0 + 1 } ?? 0 }
    /// 最大压差
    var deltaCell: Double { cells.isEmpty ? 0 : maxCell - minCell }
    /// 平均
    var avgCell: Double { cells.isEmpty ? 0 : cells.reduce(0, +) / Double(cells.count) }

    /// 有没有可显示的数据
    /// 只要有单体电压就认为有数据（总电压可能因偏移错而读不到，不该因此整页空白）
    var hasData: Bool { cellCount > 0 && !cells.isEmpty }

    static let empty = AntBmsData()
}

// MARK: - BMS 配置（从 BMS 读的保护参数）

/// 蚂蚁 BMS 的配置参数
/// 地址表来自社区验证过的实现（syssi/esphome-ant-bms）
struct AntBmsConfig: Equatable {
    /// 单体过压保护电压 V（地址 0x0000，×0.001）—— 这就是"单体满电电压"
    var cellOvervoltageProtection: Double = 0
    /// 单体过压恢复 V（0x0002）
    var cellOvervoltageRecovery: Double = 0
    /// 整包过压保护 V（0x0008，×0.1）
    var packOvervoltageProtection: Double = 0
    /// 整包过压恢复 V（0x000a）
    var packOvervoltageRecovery: Double = 0
    /// 单体欠压保护 V（0x000c）
    var cellUndervoltageProtection: Double = 0
    /// 整包欠压保护 V（0x0014）
    var packUndervoltageProtection: Double = 0
    /// 额定容量 Ah（0x00a2）
    var nominalCapacity: Double = 0
    /// 电芯串数（0x009a）
    var cellNumber: Int = 0
    /// 电芯类型（0x0098）
    var cellType: Int = 0
    /// 累计循环容量 Ah（0x00aa）
    var totalCycleCapacity: Double = 0

    /// 哪些项已经读到了
    var loadedFields: Set<String> = []

    var isEmpty: Bool { loadedFields.isEmpty }

    /// 单体满电电压：优先用 BMS 的过压保护值
    var cellFullVoltage: Double? {
        cellOvervoltageProtection > 2.0 && cellOvervoltageProtection < 5.0
            ? cellOvervoltageProtection : nil
    }

    /// 整包满电电压
    var packFullVoltage: Double? {
        packOvervoltageProtection > 20 ? packOvervoltageProtection : nil
    }

    /// 额定容量
    var capacity: Double? {
        nominalCapacity > 0 && nominalCapacity < 2000 ? nominalCapacity : nil
    }

    var cellTypeName: String {
        switch cellType {
        case 0: return "三元锂"
        case 1: return "磷酸铁锂"
        case 2: return "钛酸锂"
        default: return cellType == 0 ? "未知" : "类型 \(cellType)"
        }
    }

    static let empty = AntBmsConfig()
}

// MARK: - 寄存器地址表

enum AntRegister {
    // 电压保护
    static let cellOvervoltageProtection: UInt16 = 0x0000
    static let cellOvervoltageRecovery:   UInt16 = 0x0002
    static let packOvervoltageProtection: UInt16 = 0x0008
    static let packOvervoltageRecovery:   UInt16 = 0x000a
    static let cellUndervoltageProtection: UInt16 = 0x000c
    static let packUndervoltageProtection: UInt16 = 0x0014
    // 容量
    static let nominalCapacity:    UInt16 = 0x00a2
    static let remainingCapacity:  UInt16 = 0x00a6
    static let totalCycleCapacity: UInt16 = 0x00aa
    // 电芯
    static let cellType:   UInt16 = 0x0098
    static let cellNumber: UInt16 = 0x009a
}

// MARK: - 组帧

enum AntBmsCommand {

    /// 组一个 10 字节请求帧
    static func build(function: UInt8, address: UInt16, value: UInt8) -> Data {
        var f = [UInt8](repeating: 0, count: 10)
        f[0] = AntFrame.start1
        f[1] = AntFrame.start2
        f[2] = function
        f[3] = UInt8(address & 0xFF)
        f[4] = UInt8((address >> 8) & 0xFF)
        f[5] = value
        let crc = crc16(Array(f[1...5]))
        f[6] = UInt8(crc & 0xFF)
        f[7] = UInt8((crc >> 8) & 0xFF)
        f[8] = AntFrame.end1
        f[9] = AntFrame.end2
        return Data(f)
    }

    /// 请求状态帧
    ///
    /// 用官方 App 的探测指令，从 app-service.js 里挖到的原文：
    ///   7ea1010000f55862aa55
    /// 拆开就是 function=0x01, address=0x0000, value=0xF5
    ///
    /// CRC16(body[1..6], init 0xFFFF, poly 0xA001) = 0x6258
    /// 低字节在前 → 0x58 0x62，和官方一致。
    static func requestStatus() -> Data {
        build(function: AntFrame.status, address: 0x0000, value: 0xF5)
    }

    /// 请求设备信息
    static func requestDeviceInfo() -> Data {
        build(function: AntFrame.deviceInfo, address: 0x0000, value: 0x20)
    }

    /// 读某个寄存器
    /// - Parameters:
    ///   - address: 寄存器地址
    ///   - length: 要读几个字节（2 或 4）
    static func readRegister(_ address: UInt16, length: UInt8 = 2) -> Data {
        build(function: AntFrame.deviceInfo, address: address, value: length)
    }

    /// 一次要读的全部配置寄存器
    static func allConfigRequests() -> [(name: String, address: UInt16, length: UInt8)] {
        [
            ("单体过压保护", AntRegister.cellOvervoltageProtection, 2),
            ("单体过压恢复", AntRegister.cellOvervoltageRecovery, 2),
            ("整包过压保护", AntRegister.packOvervoltageProtection, 2),
            ("整包过压恢复", AntRegister.packOvervoltageRecovery, 2),
            ("单体欠压保护", AntRegister.cellUndervoltageProtection, 2),
            ("整包欠压保护", AntRegister.packUndervoltageProtection, 2),
            ("额定容量",     AntRegister.nominalCapacity, 4),
            ("串数",         AntRegister.cellNumber, 2),
            ("电芯类型",     AntRegister.cellType, 2),
            ("累计循环容量", AntRegister.totalCycleCapacity, 4),
        ]
    }

    /// 校验：帧头正确、长度够、CRC 对
    static func verify(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 10 else { return false }
        guard frame[0] == AntFrame.start1, frame[1] == AntFrame.start2 else { return false }
        guard frame[frame.count - 2] == AntFrame.end1,
              frame[frame.count - 1] == AntFrame.end2 else { return false }
        // CRC 在倒数 3、4 字节
        let crcLo = UInt16(frame[frame.count - 4])
        let crcHi = UInt16(frame[frame.count - 3])
        let expected = crcLo | (crcHi << 8)
        let body = Array(frame[1...(frame.count - 5)])
        return crc16(body) == expected
    }

    /// CRC16（蚂蚁用的变体：初值 0xFFFF，多项式 0xA001，低字节先）
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

// MARK: - 解析

final class AntBmsDecoder {

    private(set) var data = AntBmsData.empty

    /// 从 BMS 读回来的配置
    private(set) var config = AntBmsConfig.empty

    /// 上次成功解析出的串数（缓存）
    /// 串数不会变，用它来锁定单体电压的扫描结果，比每次硬扫可靠得多
    var lastGoodCellCount: Int = 0

    /// 解析一个完整帧
    /// - Returns: 解析出有效数据就返回 true
    @discardableResult
    func process(_ frame: [UInt8]) -> Bool {
        guard AntBmsCommand.verify(frame) else { return false }
        let function = frame[2]

        switch function {
        case AntFrame.typeStatus, AntFrame.status:
            return parseStatus(frame)
        case AntFrame.typeDeviceInfo:
            return parseDeviceInfo(frame)
        default:
            // 其它帧类型先不处理，但帧本身是有效的
            return false
        }
    }

    // MARK: - 状态帧

    /// 状态帧布局（社区验证过的真实布局，syssi/esphome-ant-bms）
    ///
    /// 数据区 d[] = frame[3 ..< frame.count-4]
    ///
    /// 关键点：单体电压之后的字段都带一个 offset = 串数 × 2
    ///
    ///   偏移      大小  内容                    换算
    ///   ──────────────────────────────────────────────────
    ///   0         1     充放电 MOS 状态
    ///   34        2×N   单体电压（N 串）        ×0.001 V
    ///   34+off    2×M   温度传感器（M 个）      int16 °C
    ///   34+off    2     MOS 温度
    ///   36+off    2     均衡器温度
    ///   38+off    2     总电压                  ×0.01 V     ⭐
    ///   40+off    2     电流                    int16 ×0.1 A ⭐
    ///   42+off    2     SOC                     ×1 %        ⭐
    ///   44+off    2     BMS 健康度              ×1 %
    ///   46+off    1     充电 MOS 状态
    ///   47+off    1     放电 MOS 状态
    ///   48+off    1     均衡器状态
    ///   49+off    1     保留
    ///   50+off    4     电池容量                ×0.000001 Ah ⭐
    ///   54+off    4     剩余容量                ×0.000001 Ah ⭐
    ///   58+off    4     累计循环容量            ×0.001 Ah    ⭐
    ///   62+off    4     功率
    ///   66+off    4     累计运行时长
    ///   70+off    4     均衡 cell 位图
    ///   74+off    2     最高单体电压            ×0.001 V
    ///   76+off    2     最高单体编号
    ///   78+off    2     最低单体电压            ×0.001 V
    ///   80+off    2     最低单体编号
    ///   82+off    2     单体压差                ×0.001 V
    ///   84+off    2     单体平均电压            ×0.001 V
    ///
    private func parseStatus(_ frame: [UInt8]) -> Bool {
        // 帧结构（实测 ANTBLE24CBUB）：
        //   7E A1 11 00 00 AA | <数据> | CRC CRC | AA 55
        //   └── 6 字节头 ──┘
        // 所以数据从 [6] 开始，到倒数第 4 字节结束
        let dataEnd = frame.count - 4
        guard dataEnd > 6 else { return false }
        let d = Array(frame[6..<dataEnd])
        guard d.count >= 40 else { return false }

        var out = AntBmsData()
        out.updatedAt = Date()
        /// 每节的均衡标志（来自单体电压字节的高 3 位）
        var balFlags: [Bool] = []

        // ── 1. 自动定串数 + 单体电压起点 + 总电压位置 ──
        //
        // 核心思路：不猜任何偏移，用数学约束反推。
        //
        //   ① 串数直接读 d[3]（BMS 自己报的，实测 0x15 = 21）
        //   ② 对每个候选起点取 N 节电压
        //   ③ 算这 N 节的合计，往后找总电压
        //   ④ 只有「合计 ≈ 总电压」的起点才是真的
        //
        // 这样无论什么型号的保护板（16S/20S/21S/24S/25S...），
        // 只要 BMS 在 d[3] 报了正确串数，就能自动对上。
        let declaredCells = Int(d[3])
        // 串数不合理时（0 或者超过 32）放弃 d[3]，改用扫描
        let cellTarget = (declaredCells >= 4 && declaredCells <= 32) ? declaredCells : 0

        var cellCount = 0
        var cellStart = 28
        var base = 0
        var resolved = false

        // 串数候选：优先用 d[3]，失败再上下浮动试几个
        var countCandidates: [Int] = []
        if cellTarget > 0 {
            countCandidates = [cellTarget, cellTarget + 1, cellTarget - 1,
                               cellTarget + 2, cellTarget - 2]
        } else {
            // 没报串数：12~28 全试
            countCandidates = Array(12...28)
        }

        for tryCount in countCandidates {
            guard tryCount >= 4, tryCount <= 32 else { continue }
            // 起点范围：头部最长见过 33，留点余量
            for start in 20...36 {
                guard start + tryCount * 2 <= d.count else { continue }

                // 取 tryCount 节，逐个校验合理性
                var cells: [Double] = []
                var ok = true
                for i in 0..<tryCount {
                    let off = start + i * 2
                    let mv = Int(d[off]) | (Int(d[off + 1] & 0x1F) << 8)
                    // 单体合理范围放宽：2.0V ~ 5.0V（兼容 LFP 和三元、以及偏高/偏低）
                    guard mv >= 2000 && mv <= 5000 else { ok = false; break }
                    cells.append(Double(mv) / 1000.0)
                }
                guard ok else { continue }

                let sum = cells.reduce(0, +)
                guard sum > 10 else { continue }

                // 在温度区之后找总电压
                let tempStart = start + tryCount * 2
                let maxOff = max(24, d.count - tempStart - 24)
                for off in stride(from: 0, through: maxOff, by: 2) {
                    let p = tempStart + off
                    guard p + 21 < d.count else { break }
                    let total = Double(readUInt16(d, p)) / 100.0
                    guard total > 5 else { continue }
                    // 合计和总电压差 < 0.3V 才算匹配
                    if abs(total - sum) < 0.3 {
                        cellStart = start
                        cellCount = tryCount
                        base = p
                        resolved = true
                        break
                    }
                }
                if resolved { break }
            }
            if resolved { break }
        }

        // 兜底：自校验全失败，退回老办法（扫描最长连续段）
        if !resolved {
            struct Candidate {
                let start: Int
                let count: Int
                let spread: Double
            }
            var candidates: [Candidate] = []
            for start in 20...40 {
                let cnt = countValidCells(d, from: start)
                guard cnt >= 5 else { continue }
                var lo = 99999, hi = 0
                for k in 0..<cnt {
                    let off = start + k * 2
                    guard off + 1 < d.count else { break }
                    let mv = Int(d[off]) | (Int(d[off + 1] & 0x1F) << 8)
                    lo = min(lo, mv)
                    hi = max(hi, mv)
                }
                let spread = lo == 99999 ? 99999.0 : Double(hi - lo) / 1000.0
                candidates.append(Candidate(start: start, count: cnt, spread: spread))
            }
            if let best = candidates.filter({ $0.spread < 0.6 }).max(by: { $0.count < $1.count })
                ?? candidates.max(by: { $0.count < $1.count }) {
                cellStart = best.start
                cellCount = best.count
                let tempStart = cellStart + cellCount * 2
                let tempCountFallback = Int(d[2])
                let nT = (tempCountFallback > 0 && tempCountFallback <= 8) ? tempCountFallback : 4
                base = tempStart + nT * 2 + 4
            }
        }

        guard cellCount > 0 else { return false }
        // 记住这次的结果，下次优先用（串数不会变）
        if cellCount >= 3 && cellCount <= 40 {
            lastGoodCellCount = cellCount
        }

        // ── 2. 单体电压 ──
        if d.count >= cellStart + cellCount * 2 {
            var cells: [Double] = []
            for i in 0..<cellCount {
                // 每节 2 字节，高 3 位是均衡标志
                var b0 = d[cellStart + i * 2]
                var b1 = d[cellStart + i * 2 + 1]
                let bal = (b1 >> 5) & 0x07
                b1 = b1 & 0x1F
                let mv = UInt16(b0) | (UInt16(b1) << 8)
                b0 = 0
                cells.append(mv >= 1000 && mv <= 5000 ? Double(mv) / 1000.0 : 0)
                if bal > 0 { balFlags.append(true) } else { balFlags.append(false) }
            }
            out.cells = cells
            out.cellCount = cellCount
            out.balancing = balFlags
        }

        // ── 2.5 温度传感器数量（BMS 自己报，不能写死）──
        //
        // d[2] 报的是温度传感器数量，但实测有对不上的情况（d[2]=4 却有 6 个温度），
        // 所以温度个数 = 从温度区起点到总电压之间有多少个 2 字节槽。
        let tempCount = Int(d[2])
        let declaredTemps = (tempCount > 0 && tempCount <= 8) ? tempCount : 4

        /// 温度开始的位置 = 单体电压之后
        let tempStart = cellStart + cellCount * 2

        // ── 2.6 温度个数 + 总电压位置 ──
        //
        // base 已经在第①步的自校验里定好了（就是「合计 ≈ 总电压」匹配到的位置）。
        // 温度区就是 tempStart 到 base 之间，每 2 字节一个。
        var nTemps = declaredTemps
        if resolved && base > tempStart {
            let slots = (base - tempStart) / 2
            // 合理范围 1~10 个；多出来的槽是 MOS 温度或其它字段
            if slots >= 1 && slots <= 10 {
                // 优先用 d[2] 报的数量，但不超过去重后的槽位
                nTemps = min(declaredTemps, slots)
                // d[2] 明显偏小时，用槽位数兜底（实测 d[2]=4 但有 6 个温度）
                if declaredTemps < slots - 1 && slots <= 8 {
                    nTemps = slots
                }
            }
        } else if !resolved {
            // 没校验成功：沿用老逻辑，在温度区后面重新找总电压
            var bestDiff = Double.greatestFiniteMagnitude
            let cellSumMv2 = out.cells.reduce(0) { $0 + $1 } * 1000.0
            let searchFrom = tempStart + nTemps * 2
            base = searchFrom + 4
            if cellSumMv2 > 1000 {
                let maxOff = max(80, d.count - searchFrom - 24)
                for off in stride(from: 0, through: maxOff, by: 2) {
                    let p = searchFrom + off
                    guard p + 21 < d.count else { break }
                    let v = readUInt16(d, p)
                    guard v > 0 else { continue }
                    let diff = abs(Double(v) / 100.0 - cellSumMv2 / 1000.0)
                    if diff < 0.5 && diff < bestDiff {
                        bestDiff = diff
                        base = p
                    }
                }
            }
        }

        let cellSumMv = out.cells.reduce(0) { $0 + $1 } * 1000.0

        // ── 3. 温度（nTemps 个）──
        var temps: [Int] = []
        for k in 0..<nTemps {
            let off = tempStart + k * 2
            guard off + 1 < d.count else { break }
            let t = Int(Int16(bitPattern: readUInt16(d, off)))
            if t > -40 && t < 120 { temps.append(t) }
        }
        if !temps.isEmpty { out.temps = temps }
        // MOS 温度紧跟在电芯温度后面
        let mosOff = tempStart + nTemps * 2
        if mosOff + 1 < d.count {
            let mosT = Int(Int16(bitPattern: readUInt16(d, mosOff)))
            if mosT > -40 && mosT < 120 { out.mosTemp = mosT }
            else { out.mosTemp = temps.first ?? 0 }
        } else {
            out.mosTemp = temps.first ?? 0
        }

        // ── 4. 总电压（×0.01V）──
        if base + 1 < d.count {
            let v = readUInt16(d, base)
            if v > 0 && v < 20000 { out.totalVoltage = Double(v) / 100.0 }
        }
        // 兜底：总电压没读到（或者离谱），就用单体电压合计
        if out.totalVoltage <= 0 || abs(out.totalVoltage * 1000 - cellSumMv) > 5000 {
            if cellSumMv > 1000 {
                out.totalVoltage = cellSumMv / 1000.0
            }
        }

        // ── 5. 电流（int16 ×0.1A，负=放电）──
        if base + 3 < d.count {
            let a = Int16(bitPattern: readUInt16(d, base + 2))
            if abs(Int(a)) < 5000 { out.current = Double(a) / 10.0 }
        }

        // ── 6. SOC（×1 %）──
        if base + 5 < d.count {
            let soc = Int(readUInt16(d, base + 4))
            if soc >= 0 && soc <= 100 { out.soc = soc }
        }

        // ── 7. BMS 自己的健康度（仅参考）──
        if base + 7 < d.count {
            let bmsSoh = Int(readUInt16(d, base + 6))
            if bmsSoh >= 0 && bmsSoh <= 100 { out.bmsSoh = bmsSoh }
        }

        // ── 8. MOS 状态（base+8 起，先放电后充电）──
        if base + 9 < d.count {
            let dsgMos = d[base + 8]
            let chgMos = d[base + 9]
            out.isCharging = (chgMos == 0x01)
            out.isDischarging = (dsgMos == 0x01)
        }

        // ── 9. 容量（uint32 × 0.000001 → Ah）──
        if base + 15 < d.count {
            let capAh = Double(readUInt32(d, base + 12)) / 1_000_000.0
            if capAh > 0 && capAh < 10000 { out.capacityTotal = capAh }
        }
        if base + 19 < d.count {
            let remAh = Double(readUInt32(d, base + 16)) / 1_000_000.0
            if remAh >= 0 && remAh < 10000 { out.capacityRemaining = remAh }
        }

        // ── 10. 累计循环容量（uint32 × 0.001 → Ah）⭐ ──
        // 在容量后面：base+20
        if base + 23 < d.count {
            let cycAh = Double(readUInt32(d, base + 20)) / 1000.0
            if cycAh >= 0 && cycAh < 10_000_000 {
                out.totalCycleCapacity = cycAh
            }
        }

        // ── 11. 循环次数 = 累计循环容量 ÷ 额定容量 ──
        let ratedCap = config.capacity ?? (out.capacityTotal > 0 ? out.capacityTotal : 0)
        if ratedCap > 0, out.totalCycleCapacity > 0 {
            out.cycles = Int((out.totalCycleCapacity / ratedCap).rounded())
        }

        // ── 12. 均衡状态（base+32）──
        if base + 35 < d.count {
            let mask = readUInt32(d, base + 32)
            out.balancingActive = mask != 0
            var bal: [Bool] = []
            for i in 0..<cellCount {
                bal.append(i < 32 ? (mask & (1 << UInt32(i))) != 0 : false)
            }
            out.balancing = bal
        }

        // ── 13. 单体极值（base+36 起，BMS 自己算好的）──
        var maxV: UInt16 = 0, minV: UInt16 = 0, maxIdx: UInt16 = 0, minIdx: UInt16 = 0
        if base + 37 < d.count { maxV = readUInt16(d, base + 36) }
        if base + 39 < d.count { maxIdx = readUInt16(d, base + 38) }
        if base + 41 < d.count { minV = readUInt16(d, base + 40) }
        if base + 43 < d.count { minIdx = readUInt16(d, base + 42) }
        if maxV >= 1000 && maxV <= 5000 { out.maxCellFromBms = Double(maxV) / 1000.0 }
        if minV >= 1000 && minV <= 5000 { out.minCellFromBms = Double(minV) / 1000.0 }
        if maxIdx <= 64 { out.maxCellIndexFromBms = Int(maxIdx) }
        if minIdx <= 64 { out.minCellIndexFromBms = Int(minIdx) }

        // ── 14. 剩余时间（BMS 自己算的，官方 App 直接显示）──
        // 实测：两帧都是 126 分钟充电剩余，和满电状态吻合
        if base + 51 < d.count {
            let t = Int(readUInt16(d, base + 50))
            // 1440 分钟（24 小时）以内才认
            if t >= 0 && t <= 1440 { out.chargeRemainMin = t }
        }
        if base + 53 < d.count {
            let t = Int(readUInt16(d, base + 52))
            if t >= 0 && t <= 1440 { out.dischargeRemainMin = t }
        }

        // ── 15. 电池类型（0xFAF1 三元锂 / 0xFAF2 铁锂 / 0xFAF3 钛酸锂）──
        if base + 57 < d.count {
            let t = Int(readUInt16(d, base + 56))
            if t >= 0xFAF0 && t <= 0xFAFF { out.chemistryCode = t }
        }

        data = out
        return true
    }

    // MARK: - 设备信息帧（配置参数）

    /// 设备信息帧的格式（社区实现）：
    ///   [0] 0x7E  [1] 0xA1  [2] 0x12（帧类型）
    ///   [3..4] 地址（低字节在前）
    ///   [5]    数据长度
    ///   [6...] 数据
    ///   [倒数4..3] CRC  [倒数2..1] AA 55
    ///
    /// ⚠️ 这个布局是按社区实现推的，第一次连真机可能对不上。
    ///    如果读出来的值明显不合理（比如过压保护 0.5V 或 60V），
    ///    说明偏移不对，需要看原始帧再调。
    private func parseDeviceInfo(_ frame: [UInt8]) -> Bool {
        let dataEnd = frame.count - 4
        guard dataEnd > 6 else { return false }

        // 地址
        let address = UInt16(frame[3]) | (UInt16(frame[4]) << 8)
        let declaredLen = Int(frame[5])
        let payload = Array(frame[6..<dataEnd])
        guard !payload.isEmpty else { return false }
        let len = min(declaredLen == 0 ? payload.count : declaredLen, payload.count)

        var cfg = config
        var matched = false

        switch address {
        case AntRegister.cellOvervoltageProtection:
            if len >= 2 {
                let mv = Double(readUInt16(payload, 0))
                // 合理范围 2.0V ~ 5.0V
                if mv >= 2000 && mv <= 5000 {
                    cfg.cellOvervoltageProtection = mv / 1000.0
                    cfg.loadedFields.insert("cellOVP")
                    matched = true
                }
            }

        case AntRegister.cellOvervoltageRecovery:
            if len >= 2 {
                let mv = Double(readUInt16(payload, 0))
                if mv >= 2000 && mv <= 5000 {
                    cfg.cellOvervoltageRecovery = mv / 1000.0
                    cfg.loadedFields.insert("cellOVR")
                    matched = true
                }
            }

        case AntRegister.packOvervoltageProtection:
            if len >= 2 {
                let dv = Double(readUInt16(payload, 0))
                // 整包过压保护：×0.1V，合理 20V ~ 200V
                if dv >= 200 && dv <= 2000 {
                    cfg.packOvervoltageProtection = dv / 10.0
                    cfg.loadedFields.insert("packOVP")
                    matched = true
                }
            }

        case AntRegister.packOvervoltageRecovery:
            if len >= 2 {
                let dv = Double(readUInt16(payload, 0))
                if dv >= 200 && dv <= 2000 {
                    cfg.packOvervoltageRecovery = dv / 10.0
                    cfg.loadedFields.insert("packOVR")
                    matched = true
                }
            }

        case AntRegister.cellUndervoltageProtection:
            if len >= 2 {
                let mv = Double(readUInt16(payload, 0))
                if mv >= 1500 && mv <= 4000 {
                    cfg.cellUndervoltageProtection = mv / 1000.0
                    cfg.loadedFields.insert("cellUVP")
                    matched = true
                }
            }

        case AntRegister.packUndervoltageProtection:
            if len >= 2 {
                let dv = Double(readUInt16(payload, 0))
                if dv >= 100 && dv <= 1500 {
                    cfg.packUndervoltageProtection = dv / 10.0
                    cfg.loadedFields.insert("packUVP")
                    matched = true
                }
            }

        case AntRegister.nominalCapacity:
            if len >= 4 {
                let ah = Double(readUInt32(payload, 0))
                // 合理范围 1Ah ~ 2000Ah
                if ah >= 1 && ah <= 2000 {
                    cfg.nominalCapacity = ah
                    cfg.loadedFields.insert("capacity")
                    matched = true
                }
            } else if len >= 2 {
                // 有的板子用 2 字节（×0.1Ah）
                let ah = Double(readUInt16(payload, 0)) / 10.0
                if ah >= 1 && ah <= 2000 {
                    cfg.nominalCapacity = ah
                    cfg.loadedFields.insert("capacity")
                    matched = true
                }
            }

        case AntRegister.cellNumber:
            if len >= 2 {
                let n = Int(readUInt16(payload, 0))
                if n >= 1 && n <= 40 {
                    cfg.cellNumber = n
                    cfg.loadedFields.insert("cellNumber")
                    matched = true
                }
            } else if len >= 1 && payload[0] >= 1 && payload[0] <= 40 {
                cfg.cellNumber = Int(payload[0])
                cfg.loadedFields.insert("cellNumber")
                matched = true
            }

        case AntRegister.cellType:
            if len >= 2 {
                let t = Int(readUInt16(payload, 0))
                if t >= 0 && t <= 10 {
                    cfg.cellType = t
                    cfg.loadedFields.insert("cellType")
                    matched = true
                }
            } else if len >= 1 && payload[0] <= 10 {
                cfg.cellType = Int(payload[0])
                cfg.loadedFields.insert("cellType")
                matched = true
            }

        case AntRegister.totalCycleCapacity:
            if len >= 4 {
                let ah = Double(readUInt32(payload, 0))
                if ah > 0 && ah < 1_000_000 {
                    cfg.totalCycleCapacity = ah
                    cfg.loadedFields.insert("cycleCapacity")
                    matched = true
                }
            }

        default:
            break
        }

        if matched {
            config = cfg
        }
        // 设备信息帧不算失败
        return true
    }

    // MARK: - 小工具

    /// 从某个偏移开始，数连续的合理单体电压（3.0~4.5V）有多少节
    /// 单体电压每节 2 字节，高 3 位是均衡标志，要掩掉
    private func countValidCells(_ d: [UInt8], from start: Int) -> Int {
        var count = 0
        while count < 40 {
            let off = start + count * 2
            guard off + 1 < d.count else { break }
            let lo = d[off]
            let hi = d[off + 1] & 0x1F
            let mv = Int(lo) | (Int(hi) << 8)
            if mv >= 3000 && mv <= 4500 {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private func readUInt16(_ d: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < d.count else { return 0 }
        return UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8)
    }

    private func readUInt32(_ d: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < d.count else { return 0 }
        return UInt32(d[offset])
            | (UInt32(d[offset + 1]) << 8)
            | (UInt32(d[offset + 2]) << 16)
            | (UInt32(d[offset + 3]) << 24)
    }
}
