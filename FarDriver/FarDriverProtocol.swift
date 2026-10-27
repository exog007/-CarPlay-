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
    var updatedAt: Date = Date()

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

        switch address {
        case 0xE2:
            // 档位 + 转速
            data.gear = Int((p[0] >> 2) & 0b11) + 1
            data.rawRpm = Int16(bitPattern: (UInt16(p[7]) << 8) | UInt16(p[6]))

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

        default:
            break
        }

        // 换算转速和时速
        let displayRpm = data.rawRpm < 0 ? 0 : data.rawRpm
        data.rpm = Double(displayRpm) * 4.0 / Double(motorPolePairs)
        data.speed = (data.rpm * wheelCircumferenceM * 60.0) / 1000.0

        data.recomputePower()
        data.updatedAt = Date()
        return true
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
