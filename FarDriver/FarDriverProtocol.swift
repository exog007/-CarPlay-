//
//  FarDriverProtocol.swift
//  远驱控制器 BLE 协议解码
//
//  协议来源：逆向自官方 App / 社区实现
//  服务 UUID: 0000ffe0-0000-1000-8000-00805f9b34fb
//  特征 UUID: 0000ffec-0000-1000-8000-00805f9b34fb
//  包长固定 16 字节，CRC16 校验（初值 0x7F3C，多项式 0xA001）
//

import Foundation
import CoreBluetooth

/// 控制器数据
struct ControllerData: Codable, Equatable {
    var voltage: Double = 0          // 电池电压 V
    var current: Double = 0          // 母线电流 A（负值 = 回收）
    var power: Double = 0            // 功率 W
    var rpm: Double = 0              // 电机转速
    var rawRpm: Int16 = 0
    var gear: Int = 0                // 档位
    var speed: Double = 0            // 时速 km/h
    var mosTemp: Int = 0             // 控制器/MOS 温度 °C
    var motorTemp: Int = 0           // 电机温度 °C
    var soc: Int = 0                 // 电量 %
    var isRegen: Bool = false        // 动能回收中
    var faultCode: Int = 0           // 故障码原始值（0 = 无故障）
    var faultText: String = ""       // 故障描述（多故障用「、」分隔）
    var faultRaw: String = ""        // 原始字节，调试用，例如 "A4 08 00 00"
    var faultFrameSeen: Bool = false // 有没有真的收到过故障帧
    /// 0xEE 帧原始 12 字节（调试用，find P gear）
    var eeRaw: String = ""
    /// 0xEE 的前两个字节：引脚分析类型 + 位索引
    var eePinType: Int = -1
    var eePinBit: Int = -1
    /// 0xE2 帧原始 12 字节（调试用）
    var e2Raw: String = ""
    /// 0xE2 的 p[0] 原始值（档位/方向/P 档都在这一个字节里）
    var e2Byte0: Int = -1
    /// P 档是否挂入（来自 0xE2 的 p[0] bit0）
    ///
    /// 实测：挂入 P 时 p[0] = 0x80（bit0 = 0），解除时 p[0] = 0x81（bit0 = 1）
    var pGearOn: Bool = false
    /// 是否正在刹车（来自 0xE2 的 p[3] bit7）
    ///
    /// 实测：捏刹车 p[3] = 0x80，松开 p[3] = 0x00
    var braking: Bool = false

    /// 控制器自己算的速度（0xE2 的 p[8..9]，单位未定，配合 0xD0 参数换算）
    var measureSpeed: Int = 0
    /// 轮径相关参数（来自 0xD0 帧），用于把 measureSpeed 换成 km/h
    var wheelRadius: Int = 0
    var wheelWidth: Int = 0
    var wheelRatio: Int = 0
    var rateRatio: Int = 0
    /// 控制器自己给的整车速度（0xD0 的 p[6]，直接是 km/h）
    var controllerSpeedKmh: Double = 0
    /// 有没有收到过 0xD0 帧
    var d0Seen: Bool = false
    /// 有没有收到过 0xE2 帧（判断 pGearOn 是否可信）
    var e2Seen: Bool = false
    var updatedAt: Date = Date()

    /// 有没有故障：只有解析出明确故障位才算
    var hasFault: Bool { !faultText.isEmpty }

    /// 能算功率就自动算
    mutating func recomputePower() {
        if voltage > 0 {
            power = voltage * current
            isRegen = current < 0
        }
    }

    static let empty = ControllerData()
}

/// BLE 常量
enum FarDriverBLE {
    static let serviceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    static let characteristicUUID = CBUUID(string: "0000FFEC-0000-1000-8000-00805F9B34FB")

    /// 控制器上报的地址序列（包索引 → 寄存器地址）
    static let flashReadAddr: [UInt8] = [
        0xE2, 0xE8, 0xEE, 0xE4, 0x06, 0x0C, 0x12, 0xE2, 0xE8, 0xEE, 0x18, 0x1E, 0x24, 0x2A,
        0xE2, 0xE8, 0xEE, 0x30, 0x5D, 0x63, 0x69, 0xE2, 0xE8, 0xEE, 0x7C, 0x82, 0x88, 0x8E,
        0xE2, 0xE8, 0xEE, 0x94, 0x9A, 0xA0, 0xA6, 0xE2, 0xE8, 0xEE, 0xAC, 0xB2, 0xB8, 0xBE,
        0xE2, 0xE8, 0xEE, 0xC4, 0xCA, 0xD0, 0xE2, 0xE8, 0xEE, 0xD6, 0xDC, 0xF4, 0xFA,
    ]
}

/// 协议解码器
final class FarDriverDecoder {

    /// 车友常见参数，按需改
    var wheelCircumferenceM: Double = 1.416   // 轮周长（米），17寸胎约 1.416
    var motorPolePairs: Int = 20              // 电机极对数

    private(set) var data = ControllerData.empty

    /// 缓存每个帧号最近一次的原始数据（14 字节）
    /// 用来给「参数查看」页取数，不参与实时显示
    private(set) var frameCache: [Int: [UInt8]] = [:]

    /// 解一个 16 字节的包
    /// - Returns: 解出来了就返回 true
    @discardableResult
    func process(_ packet: Data) -> Bool {
        guard packet.count == 16 else { return false }
        guard Self.verifyCRC(packet) else { return false }

        let bytes = [UInt8](packet)
        let id = Int(bytes[1] & 0x3F)
        guard id < FarDriverBLE.flashReadAddr.count else { return false }
        let address = FarDriverBLE.flashReadAddr[id]

        // 数据从第 3 个字节开始
        let p = Array(bytes[2...])

        // 缓存原始数据
        frameCache[id] = p

        switch address {
        case 0xE2:
            // 档位 + 转速
            data.gear = Int((p[0] >> 2) & 0b11) + 1
            data.rawRpm = Int16(bitPattern: (UInt16(p[7]) << 8) | UInt16(p[6]))
            // P 档：p[0] 的 bit0，0 = 挂入 P，1 = 解除
            // 实测：P 档 p[0]=0x80，解除 p[0]=0x81
            data.pGearOn = (p[0] & 0x01) == 0
            // 刹车：p[3] 的 bit7，1 = 刹车中
            // 实测：捏刹车 p[3]=0x80，松开 p[3]=0x00
            data.braking = (p[3] & 0x80) != 0
            // 控制器自己测的速度原始值
            data.measureSpeed = Int(UInt16(p[8]) | (UInt16(p[9]) << 8))
            data.e2Seen = true
            data.e2Byte0 = Int(p[0])

        case 0xD0:
            // 轮径参数 + 控制器算好的平均速度
            // 布局（社区逆向）：
            //   p[0..1] Data0        p[2] BMQHALL       p[3] AVGPower
            //   p[4] WheelRatio      p[5] WheelRadius  p[6] AVGSpeed
            //   p[7] WheelWidth      p[8..9] RateRatio
            data.wheelRatio  = Int(p[4])
            data.wheelRadius = Int(p[5])
            data.controllerSpeedKmh = Double(p[6])
            data.wheelWidth  = Int(p[7])
            data.rateRatio   = Int(UInt16(p[8]) | (UInt16(p[9]) << 8))
            data.d0Seen = true
            data.e2Raw = Self.hex(p, count: 12)

        case 0xEE:
            // 引脚状态帧：p[0] = 引脚分析类型（P=0, BC=1, RE=2, SDH=3, SDL=4, XH=5, SEAT=6）
            //           p[1] = 该功能对应的位索引
            data.eePinType = Int(p[0])
            data.eePinBit = Int(p[1])
            data.eeRaw = Self.hex(p, count: 12)

        case 0xE8:
            // 电压 + 电流
            let v = Double((UInt16(p[1]) << 8) | UInt16(p[0])) / 10.0
            if v >= 0 && v <= 100 { data.voltage = v }

            let a = Double(Int16(bitPattern: (UInt16(p[5]) << 8) | UInt16(p[4]))) / 4.0
            if a >= -100 && a <= 300 { data.current = a }

        case 0xD6:
            // 控制器（MOS）温度
            let t = Int16(bitPattern: (UInt16(p[11]) << 8) | UInt16(p[10]))
            if t > -20 && t < 100 { data.mosTemp = Int(t) }

        case 0xF4:
            // 电机温度 + SOC
            let mt = Int16(bitPattern: (UInt16(p[1]) << 8) | UInt16(p[0]))
            if mt > -20 && mt < 200 { data.motorTemp = Int(mt) }
            data.soc = Int(p[3])

        case 0xC4:
            // 故障码帧
            // 官方故障表来自 MotorNet6.dll：第 0 项「系统正常」，1...18 是各故障
            // 位定义：bit N == 1 表示「故障 N」（bit 0 不算故障）
            // 最多到 bit 18，所以要 3 个字节才装得下
            let code32 = UInt32(p[0]) | (UInt32(p[1]) << 8) | (UInt32(p[2]) << 16)
            data.faultCode = Int(code32)
            data.faultFrameSeen = true
            data.faultText = FarDriverFaultCodes.describe(bits: code32)
            // 保留原始字节，方便对照官方 App 排查
            data.faultRaw = String(format: "%02X %02X %02X %02X  %02X %02X %02X %02X  %02X %02X %02X %02X  %02X %02X",
                                   p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
                                   p[8], p[9], p[10], p[11], p[12], p[13])

        default:
            break
        }

        // 换算转速和时速
        let displayRpm = data.rawRpm < 0 ? 0 : data.rawRpm
        data.rpm = Double(displayRpm) * 4.0 / Double(motorPolePairs)

        // ── 速度计算 ──
        //
        // 只用「转速 × 轮周长」这一条路。
        // 之前试图用 0xD0 帧的轮径参数，实测读到的全是无效值（meas 恒为 65534），
        // 所以那条路彻底停用。
        //
        // 用户可以在设置里用「速度微调」把显示值上下修正，弥补轮周长误差。
        let baseSpeed = (data.rpm * wheelCircumferenceM * 60.0) / 1000.0
        // 微调系数存在 UserDefaults，默认 1.0
        let trim: Double = {
            let v = UserDefaults.standard.double(forKey: "speedTrim")
            return (v > 0.1 && v < 5.0) ? v : 1.0
        }()
        data.speed = baseSpeed * trim

        data.recomputePower()
        data.updatedAt = Date()
        return true
    }

    /// 字节数组转 hex 字符串（调试用）
    static func hex(_ bytes: [UInt8], count: Int) -> String {
        let n = min(count, bytes.count)
        return bytes[0..<n].map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// CRC16 校验（Modbus 风格，初值 0x7F3C）
    static func verifyCRC(_ packet: Data) -> Bool {
        guard packet.count == 16 else { return false }
        let bytes = [UInt8](packet)
        var crc: UInt16 = 0x7F3C
        for i in 0..<14 {
            crc ^= UInt16(bytes[i])
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        let expected = (UInt16(bytes[15]) << 8) | UInt16(bytes[14])
        return crc == expected
    }

    func reset() {
        data = .empty
    }
}
