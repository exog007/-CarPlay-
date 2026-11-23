//
//  AnCheManager.swift
//  AnChe 协议通信管理器
//
//  在 ObdManager 的 BLE 连接之上，用 AnChe 帧格式收发数据。
//
//  实测确认（2026-11-23）：
//    发 13 00 06 00 03 1C → 回 00 00 05 00 05
//    发 13 00 06 00 03 FF → 回 00 00 05 01 06
//    发 AA BB CC          → 无响应
//

import Foundation
import Combine
import CoreBluetooth

final class AnCheManager: NSObject, ObservableObject {

    static let shared = AnCheManager()

    // MARK: - 状态

    /// 是否已握手（收到过任何合法 AnChe 帧）
    @Published private(set) var handshaked = false
    /// 最近一次响应说明
    @Published private(set) var lastStatus = ""
    /// 收到的所有帧（调试用）
    @Published private(set) var rxLog: [String] = []
    /// 发送日志
    @Published private(set) var txLog: [String] = []
    /// 已读到的数据流值：ID -> 值
    @Published private(set) var values: [String: Double] = [:]

    /// 收到帧的回调
    var onFrame: ((AnCheFrame) -> Void)?

    // MARK: - 内部

    private var rxBuffer: [UInt8] = []
    /// 正在等待响应的命令类型
    private var pendingType: AnCheFrameType?
    private var pendingTimer: Timer?
    private var pendingCompletion: ((AnCheFrame?) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - 发送

    /// 发一帧并等响应
    func send(_ bytes: [UInt8],
              expectType: AnCheFrameType? = nil,
              timeout: TimeInterval = 2.0,
              completion: ((AnCheFrame?) -> Void)? = nil) {

        guard ObdManager.shared.status.isConnected,
              let tx = ObdManager.shared.txCharRef,
              let peripheral = ObdManager.shared.peripheralRef else {
            lastStatus = "未连接"
            completion?(nil)
            return
        }

        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        txLog.append(">>> \(hex)")
        if txLog.count > 200 { txLog.removeFirst(txLog.count - 200) }

        pendingType = expectType
        pendingCompletion = completion

        pendingTimer?.invalidate()
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            let cb = self.pendingCompletion
            self.pendingCompletion = nil
            self.pendingType = nil
            self.lastStatus = "超时（\(timeout)s 无响应）"
            cb?(nil)
        }
        RunLoop.main.add(t, forMode: .common)
        pendingTimer = t

        let data = Data(bytes)
        peripheral.writeValue(data, for: tx,
                              type: ObdManager.shared.txNeedsResponseRef ? .withResponse : .withoutResponse)
    }

    /// 发网络检测（心跳）
    func ping(completion: ((Bool) -> Void)? = nil) {
        send(AnCheCodec.networkCheck, expectType: .networkCheck, timeout: 1.5) { [weak self] frame in
            guard let self else { completion?(false); return }
            if let f = frame, f.payload.first == 0x00 {
                self.handshaked = true
                self.lastStatus = "✅ 协议握手成功（网络检测正常）"
                completion?(true)
            } else if let f = frame, f.payload.first == 0x01 {
                self.lastStatus = "⚠️ 模块回报校验错误"
                completion?(false)
            } else {
                self.lastStatus = "⚠️ 无响应"
                completion?(false)
            }
        }
    }

    /// 发复位
    func reset(completion: ((Bool) -> Void)? = nil) {
        send(AnCheCodec.reset, expectType: .resetResponse, timeout: 2.0) { [weak self] frame in
            guard let self else { completion?(false); return }
            if frame != nil {
                self.lastStatus = "✅ 复位成功"
                completion?(true)
            } else {
                self.lastStatus = "⚠️ 复位无响应"
                completion?(false)
            }
        }
    }

    /// 请求单个数据流
    func requestStream(_ code: AnCheCode, completion: ((Double?) -> Void)? = nil) {
        let bytes = AnCheCodec.requestSingleStream(id: code.id)
        send(bytes, timeout: 2.0) { [weak self] frame in
            guard let self else { completion?(nil); return }
            guard let f = frame, !f.payload.isEmpty else {
                completion?(nil)
                return
            }
            let v = Self.decodeValue(f.payload)
            if let v {
                self.values[code.id] = v
            }
            completion?(v)
        }
    }

    // MARK: - 接收

    /// ObdManager 收到通知时调用
    func handleIncoming(_ data: Data) {
        rxBuffer.append(contentsOf: [UInt8](data))

        let (frames, rest) = AnCheCodec.decode(rxBuffer)
        rxBuffer = rest

        for f in frames {
            let hex = f.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            rxLog.append("< \(f.typeName) [\(hex)]")
            if rxLog.count > 300 { rxLog.removeFirst(rxLog.count - 300) }

            // 任何合法帧都说明协议握上了
            handshaked = true

            onFrame?(f)

            // 分发给等待中的调用
            if pendingCompletion != nil {
                pendingTimer?.invalidate()
                pendingTimer = nil
                let cb = pendingCompletion
                pendingCompletion = nil
                pendingType = nil
                cb?(f)
            }
        }
    }

    func clearLog() {
        rxLog.removeAll()
        txLog.removeAll()
        rxBuffer.removeAll()
        values.removeAll()
        handshaked = false
        lastStatus = ""
    }

    // MARK: - 值和 ID 解码

    /// 从 payload 猜一个数值
    ///
    /// 目前不知道编码规则，先按「前两字节大端」和各种常见公式试：
    ///   · 2 字节大端
    ///   · 2 字节大端 / 4（转速）
    ///   · 2 字节大端 / 10
    ///   · 2 字节大端 / 100
    ///   · 1 字节
    static func decodeValue(_ payload: [UInt8]) -> Double? {
        guard !payload.isEmpty else { return nil }
        if payload.count >= 2 {
            let raw = Double(Int(payload[0]) << 8 | Int(payload[1]))
            return raw
        }
        return Double(payload[0])
    }

    /// 把 payload 转成可读描述（调试用）
    static func describePayload(_ payload: [UInt8]) -> String {
        guard !payload.isEmpty else { return "(空)" }
        var parts: [String] = []
        if payload.count >= 2 {
            let big = Int(payload[0]) << 8 | Int(payload[1])
            parts.append("BE=\(big)")
        }
        if payload.count >= 4 {
            let big4 = (Int(payload[0]) << 24) | (Int(payload[1]) << 16)
                     | (Int(payload[2]) << 8) | Int(payload[3])
            parts.append("BE4=\(big4)")
        }
        if let s = String(bytes: payload, encoding: .ascii),
           s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0.isWhitespace) }) {
            parts.append("ASCII=\"\(s.trimmingCharacters(in: .whitespaces))\"")
        }
        return parts.joined(separator: " ")
    }
}
