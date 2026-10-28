//
//  FarDriverCommand.swift
//  远驱控制器 BLE 指令构造
//
//  ⚠️⚠️ 重要说明 ⚠️⚠️
//
//  下面「进入自学习 / 取消自学」的指令字节，官方 App 是 AOT 编译过的二进制，
//  我能从 DLL 里挖到参数名和文案，但挖不到指令的确切拼法。
//
//  这份实现在**没有真机验证过**，可能：
//    • 完全没反应
//    • 控制器返回错误帧
//    • 极端情况让控制器进入异常状态（极低概率，但存在）
//
//  所以界面里把这条路径标成了「试验性」，并且发送前强制确认两次。
//
//  要拿到可靠指令，需要：
//    用官方 App 连接控制器，做一次自学习，
//    同时用 nRF Connect 之类的工具抓一次 BLE 写入日志，
//    把那几帧 16 字节的数据发给我，我照着改。
//

import Foundation

enum FarDriverCommand {

    /// 指令包长度（和上报帧一致，16 字节）
    private static let packetLength = 16

    // MARK: - 自学习

    /// 进入自学习
    /// 帧结构猜测：byte0 = 0xAA(写), byte1 = 命令号, byte2... = 参数, 末尾 CRC16
    static func enterSelfLearn() -> Data {
        build(command: 0x02, payload: [0x01])
    }

    /// 取消自学
    static func exitSelfLearn() -> Data {
        build(command: 0x02, payload: [0x00])
    }

    // MARK: - 组包

    /// 组一个 16 字节指令包
    /// - Parameters:
    ///   - command: 命令号
    ///   - payload: 载荷（最多 13 字节）
    static func build(command: UInt8, payload: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: packetLength)
        bytes[0] = 0xAA           // 写入标记
        bytes[1] = command
        for (i, b) in payload.prefix(13).enumerated() {
            bytes[2 + i] = b
        }
        let crc = crc16(bytes, length: 14)
        bytes[14] = UInt8(crc & 0xFF)
        bytes[15] = UInt8((crc >> 8) & 0xFF)
        return Data(bytes)
    }

    /// 和上报帧同样的 CRC16（初值 0x7F3C，多项式 0xA001）
    static func crc16(_ bytes: [UInt8], length: Int) -> UInt16 {
        var crc: UInt16 = 0x7F3C
        for i in 0..<length {
            crc ^= UInt16(bytes[i])
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}
