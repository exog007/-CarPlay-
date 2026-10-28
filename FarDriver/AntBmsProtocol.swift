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
    var cycles: Int = 0                 // 循环次数
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

    /// 最高单体
    var maxCell: Double { cells.max() ?? 0 }
    var minCell: Double { cells.min() ?? 0 }
    var maxCellIndex: Int { cells.firstIndex(of: maxCell).map { $0 + 1 } ?? 0 }
    var minCellIndex: Int { cells.firstIndex(of: minCell).map { $0 + 1 } ?? 0 }
    /// 最大压差
    var deltaCell: Double { cells.isEmpty ? 0 : maxCell - minCell }
    /// 平均
    var avgCell: Double { cells.isEmpty ? 0 : cells.reduce(0, +) / Double(cells.count) }

    var hasData: Bool { cellCount > 0 && totalVoltage > 0 }

    static let empty = AntBmsData()
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

    /// 请求状态帧（这是主指令）
    static func requestStatus() -> Data {
        build(function: AntFrame.status, address: 0x0000, value: 0xBE)
    }

    /// 请求设备信息
    static func requestDeviceInfo() -> Data {
        build(function: AntFrame.deviceInfo, address: 0x0000, value: 0x20)
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

    /// 状态帧里装的东西：
    /// 总电压、电流、SOC、剩余容量、循环次数、串数、单体电压数组、温度
    /// 不同年份的板子字段偏移略有差异，这里按社区实现的主流布局解析，
    /// 同时做了范围保护 —— 异常值不会被当真。
    private func parseStatus(_ frame: [UInt8]) -> Bool {
        // 数据区：从 [3] 开始，到 CRC 前
        let dataEnd = frame.count - 4
        guard dataEnd > 3 else { return false }
        let d = Array(frame[3..<dataEnd])
        guard d.count >= 20 else { return false }

        var out = AntBmsData()
        out.updatedAt = Date()

        // 总电压：偏移 4，单位 0.01V
        let v = readUInt32(d, 4)
        if v > 0 && v < 20000 { out.totalVoltage = Double(v) / 100.0 }

        // 电流：偏移 8，有符号，单位 0.01A（负=放电）
        let a = Int32(bitPattern: readUInt32(d, 8))
        if abs(a) < 100000 { out.current = Double(a) / 100.0 }

        // 剩余容量：偏移 12，0.001Ah
        let capR = readUInt32(d, 12)
        if capR < 1000000 { out.capacityRemaining = Double(capR) / 1000.0 }

        // 设计容量：偏移 16，0.001Ah
        let capT = readUInt32(d, 16)
        if capT < 1000000 { out.capacityTotal = Double(capT) / 1000.0 }

        // 循环次数：偏移 20，1 次
        if d.count >= 24 {
            let cy = readUInt16(d, 20)
            if cy < 20000 { out.cycles = Int(cy) }
        }

        // SOC：偏移 22（有的板子在 24）
        if d.count >= 26 {
            let s = Int(d[22])
            if s <= 100 { out.soc = s }
            else if Int(d[24]) <= 100 { out.soc = Int(d[24]) }
        }

        // 串数：偏移 22 或 24 附近。用「单体数组能装下多少」来校验
        // 社区实现里，串数在偏移 24（1 字节）
        var cellCount = 0
        if d.count >= 26 { cellCount = Int(d[24]) }
        if cellCount <= 0 || cellCount > 40 {
            // 兜底：用剩余长度反推
            let remain = d.count - 26
            cellCount = max(0, min(40, remain / 2))
        }

        // 单体电压：偏移 26 开始，每节 2 字节，单位 mV
        if cellCount > 0 && d.count >= 26 + cellCount * 2 {
            var cells: [Double] = []
            for i in 0..<cellCount {
                let mv = readUInt16(d, 26 + i * 2)
                // 合理范围 1.0V ~ 5.0V
                if mv >= 1000 && mv <= 5000 {
                    cells.append(Double(mv) / 1000.0)
                } else {
                    cells.append(0)
                }
            }
            out.cells = cells
            out.cellCount = cellCount
        }

        // 温度：单体之后，每 2 字节一个，单位 0.1K 或 °C
        let tempStart = 26 + cellCount * 2
        if d.count >= tempStart + 6 {
            var temps: [Int] = []
            for i in 0..<3 {
                let raw = readUInt16(d, tempStart + i * 2)
                // 蚂蚁温度是 0.1K，减去 2731 得 °C
                let celsius = Int(raw) - 2731
                if celsius > -40 && celsius < 100 {
                    temps.append(celsius / 10)
                } else {
                    let plain = Int(raw)
                    if plain > -40 && plain < 100 {
                        temps.append(plain)
                    } else {
                        temps.append(0)
                    }
                }
            }
            out.temps = temps
            out.mosTemp = temps.first ?? 0
        }

        // 状态位
        let status = readUInt32(d, 0)
        out.protectionStatus = status
        out.isCharging = (status & 0x01) != 0
        out.isDischarging = (status & 0x02) != 0

        data = out
        return true
    }

    // MARK: - 设备信息帧

    private func parseDeviceInfo(_ frame: [UInt8]) -> Bool {
        // 设备信息帧暂时不解析细节，只要确认能收到就说明协议通
        return true
    }

    // MARK: - 小工具

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
