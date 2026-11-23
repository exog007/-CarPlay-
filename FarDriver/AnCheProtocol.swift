//
//  AnCheProtocol.swift
//  金奔腾 / AnChe 私有诊断协议
//
//  从 MTB APK（com.jbt.mds.mtb）反编译还原：
//    · 帧格式：[类型 1B][长度 2B 大端][数据 nB][校验和 1B]
//    · 校验和：前面所有字节累加，取低 8 位
//    · 传输：原始二进制，不带 \r \n
//
//  实测确认（2026-11-23）：
//    发 13 00 06 00 03 1C  → 回 00 00 05 00 05  (正常)
//    发 13 00 06 00 03 FF  → 回 00 00 05 01 06  (校验错误)
//    发 AA BB CC           → 无响应
//  说明模块确实在按此格式解析并校验。
//

import Foundation

// MARK: - 帧类型

enum AnCheFrameType: UInt8 {
    /// 网络检测（心跳）
    case networkCheck = 0
    /// 单数据流（请求）
    case singleDataStream = 1
    /// 多数据流（请求）
    case multiDataStream = 2
    /// 全部数据流（请求）
    case allDataStream = 3
    /// 错误数据
    case errorData = 4
    /// 发单数据流
    case sendSingleDataStream = 5
    /// 发多数据流
    case sendMultiDataStream = 6
    /// 等待检测车辆
    case waitCheckCar = 7
    /// 检测结果
    case checkResult = 10
    /// 数据流结果
    case dataStreamResult = 14
    /// 发 DTC 数据
    case sendDtc = 17
    /// 复位响应
    case resetResponse = 19
    /// 发图片
    case sendImage = 20
    /// 发 JSON 数据流
    case sendJsonDataStream = 21
    /// 时间同步
    case timeSync = 22
    /// JSON 单数据流
    case sendJsonSingle = 23
    /// 软件版本
    case softwareVersion = 24
    /// 蓝牙状态
    case bluetoothStatus = 25
    /// 开始 OBD
    case startObd = 26
    /// 重发 OBD 结果
    case resendObdResult = 28
    /// 重发网络报警码
    case resendNetWarning = 29
    /// 冻结帧
    case freezeFrame = 30
    /// 发文件
    case sendFile = 238      // 0xEE

    var name: String {
        switch self {
        case .networkCheck:        return "网络检测"
        case .singleDataStream:    return "单数据流请求"
        case .multiDataStream:     return "多数据流请求"
        case .allDataStream:       return "全部数据流请求"
        case .errorData:           return "错误"
        case .sendSingleDataStream: return "单数据流应答"
        case .sendMultiDataStream: return "多数据流应答"
        case .waitCheckCar:        return "等待检测"
        case .checkResult:         return "检测结果"
        case .dataStreamResult:    return "数据流结果"
        case .sendDtc:             return "故障码"
        case .resetResponse:       return "复位应答"
        case .sendImage:           return "图片"
        case .sendJsonDataStream:  return "JSON 数据流"
        case .timeSync:            return "时间同步"
        case .sendJsonSingle:      return "JSON 单流"
        case .softwareVersion:     return "软件版本"
        case .bluetoothStatus:     return "蓝牙状态"
        case .startObd:            return "开始 OBD"
        case .resendObdResult:     return "重发 OBD"
        case .resendNetWarning:    return "重发报警"
        case .freezeFrame:         return "冻结帧"
        case .sendFile:            return "文件"
        }
    }
}

// MARK: - 帧结构

struct AnCheFrame {
    /// 帧类型
    let type: UInt8
    /// 数据部分（不含头尾）
    let payload: [UInt8]

    var typeName: String {
        AnCheFrameType(rawValue: type)?.name ?? "未知(\(type))"
    }

    /// 完整字节（含头尾），可直接发送
    var bytes: [UInt8] {
        var out: [UInt8] = []
        let totalLen = 1 + 2 + payload.count + 1   // 类型1 + 长度2 + 数据 + 校验1
        out.append(type)
        out.append(UInt8((totalLen >> 8) & 0xFF))
        out.append(UInt8(totalLen & 0xFF))
        out.append(contentsOf: payload)
        // 校验和：前面所有字节累加 & 0xFF
        var sum = 0
        for b in out { sum += Int(b) }
        out.append(UInt8(sum & 0xFF))
        return out
    }

    var hex: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - 编解码器

enum AnCheCodec {

    /// 校验和：累加取低 8 位
    static func checksum(_ bytes: [UInt8], upTo end: Int) -> UInt8 {
        var sum = 0
        for i in 0..<min(end, bytes.count) {
            sum += Int(bytes[i])
        }
        return UInt8(sum & 0xFF)
    }

    /// 组一个帧
    static func encode(type: AnCheFrameType, payload: [UInt8]) -> [UInt8] {
        AnCheFrame(type: type.rawValue, payload: payload).bytes
    }

    /// 从字节流里切出所有完整帧
    ///
    /// 返回 (帧列表, 剩余未完成的字节)
    static func decode(_ buffer: [UInt8]) -> (frames: [AnCheFrame], rest: [UInt8]) {
        var frames: [AnCheFrame] = []
        var i = 0
        let n = buffer.count

        while i + 3 <= n {
            let type = buffer[i]
            let lenHigh = Int(buffer[i + 1])
            let lenLow = Int(buffer[i + 2])
            let frameLen = (lenHigh << 8) | lenLow

            // 合理性检查：长度至少 4（头3+校验1），最多 102400
            guard frameLen >= 4 && frameLen <= 102400 else {
                i += 1
                continue
            }
            // 还不够一帧，等下次
            guard i + frameLen <= n else { break }

            // 校验和
            let expectSum = checksum(buffer, upTo: i + frameLen - 1)
            let actualSum = buffer[i + frameLen - 1]

            if expectSum == actualSum {
                let payload = Array(buffer[(i + 3)..<(i + frameLen - 1)])
                frames.append(AnCheFrame(type: type, payload: payload))
                i += frameLen
            } else {
                // 校验失败，跳过这个字节继续找
                i += 1
            }
        }

        let rest = i < n ? Array(buffer[i..<n]) : []
        return (frames, rest)
    }

    // MARK: - 常用指令

    /// 网络检测（心跳）—— 最基础的探活帧
    ///
    /// 实测：发这个模块会回 `00 00 05 00 05`
    static var networkCheck: [UInt8] {
        encode(type: .networkCheck, payload: [0x00])
    }

    /// 复位
    ///
    /// 反编译：sendMessage(new byte[]{19, 0, 6, 0, 3, 28}, 6)
    static var reset: [UInt8] {
        [0x13, 0x00, 0x06, 0x00, 0x03, 0x1C]
    }

    /// 请求单个数据流
    ///
    /// 反编译 sendSingleDataStream：
    ///   [0]=5, [1..2]=长度, [3..4]=显示编号, [5..]=数据流ID(ASCII), [last]=校验和
    static func requestSingleStream(id: String, showNum: Int = 0) -> [UInt8] {
        var payload: [UInt8] = []
        payload.append(UInt8((showNum >> 8) & 0xFF))
        payload.append(UInt8(showNum & 0xFF))
        payload.append(contentsOf: Array(id.utf8))
        return encode(type: .sendSingleDataStream, payload: payload)
    }

    /// 请求全部数据流
    static var requestAllStreams: [UInt8] {
        encode(type: .allDataStream, payload: [])
    }
}
