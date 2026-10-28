//
//  AntBmsManager.swift
//  蚂蚁 BMS 蓝牙连接管理（和远驱控制器独立，互不干扰）
//

import Foundation
import CoreBluetooth
import Combine

final class AntBmsManager: NSObject, ObservableObject {

    static let shared = AntBmsManager()

    // MARK: - 状态

    @Published private(set) var data = AntBmsData.empty
    @Published private(set) var connected = false
    @Published private(set) var scanning = false
    @Published private(set) var deviceName = ""
    @Published private(set) var lastResponseAt: Date?
    @Published private(set) var errorMsg: String?
    @Published private(set) var rawFrameHex: String = ""
    @Published private(set) var framesReceived = 0
    @Published private(set) var discovered: [(id: UUID, name: String, rssi: Int)] = []

    /// 从 BMS 读回来的配置（保护电压、容量等）
    @Published private(set) var bmsConfig = AntBmsConfig.empty
    /// 读配置失败的原因
    @Published private(set) var configError: String?
    /// 内部计数
    private var readConfigAttempt = 0

    // MARK: - 内部

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private let decoder = AntBmsDecoder()
    private var pollTimer: Timer?
    private var responseBuffer: [UInt8] = []

    /// 最近若干次电流采样（用来做 30 秒平滑，避免时间估算乱跳）
    private var currentSamples: [Double] = []
    /// 本次充电过程中见过的最大的充电电流（用来判断是否进入 CV 阶段）
    private var peakChargeCurrent: Double = 0

    /// 30 秒滑动平均电流
    var smoothedCurrent: Double {
        guard !currentSamples.isEmpty else { return data.current }
        return currentSamples.reduce(0, +) / Double(currentSamples.count)
    }

    /// 满功率充电电流（本次充电过程中的峰值）
    var fullChargeCurrent: Double {
        max(peakChargeCurrent, 1.0)
    }

    /// 单体平均电压（CV 阶段用它算时间）
    var avgCellVoltage: Double {
        data.cells.isEmpty ? 0 : data.cells.reduce(0, +) / Double(data.cells.count)
    }

    /// 电压历史（用来算恒压阶段的爬升速度）
    private(set) var voltageHistory: [(time: Date, cellVoltage: Double)] = []

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// 记一笔电压采样
    private func recordVoltage(_ cellV: Double) {
        guard cellV > 1.0 else { return }
        let now = Date()
        // 只在充电时记录（电流为正）
        guard smoothedCurrent > 0.5 else {
            // 不充电就把历史清掉，下次充电重新开始
            if !voltageHistory.isEmpty { voltageHistory.removeAll() }
            return
        }
        voltageHistory.append((now, cellV))
        // 只保留最近 10 分钟
        voltageHistory.removeAll { now.timeIntervalSince($0.time) > 600 }
    }

    /// 记一笔电流采样（每收到一次状态帧调用一次）
    private func recordCurrent(_ amp: Double) {
        // 采样窗口：轮询是 2 秒一次，15 个 ≈ 30 秒
        currentSamples.append(amp)
        if currentSamples.count > 15 {
            currentSamples.removeFirst(currentSamples.count - 15)
        }
        // 充电时刷新峰值
        if amp > 1.0 {
            peakChargeCurrent = max(peakChargeCurrent, amp)
        }
        // 掉落电就不保留峰值，下次充电重新测
        if amp < -1.0 {
            peakChargeCurrent = 0
        }
    }

    // MARK: - 扫描

    func startScan() {
        guard central.state == .poweredOn else {
            errorMsg = "蓝牙不可用"
            return
        }
        discovered.removeAll()
        scanning = true
        errorMsg = nil
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.scanning else { return }
            self.stopScan()
            if self.discovered.isEmpty {
                self.errorMsg = "15 秒内没搜到设备。确认 BMS 已通电、手机蓝牙已开"
            }
        }
    }

    func stopScan() {
        central.stopScan()
        scanning = false
    }

    func connect(to id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            errorMsg = "设备已不可用，重新扫描"
            return
        }
        central.stopScan()
        scanning = false
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "蚂蚁BMS"
        errorMsg = "连接中…"
        central.connect(p, options: nil)
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        characteristic = nil
        connected = false
        deviceName = ""
        data = .empty
    }

    /// 手动发一次状态请求
    func requestNow() {
        sendStatusRequest()
    }

    /// 手动重新读一遍配置
    func reloadConfig() {
        guard connected, characteristic != nil else {
            errorMsg = "没连上，读不了配置"
            return
        }
        configError = nil
        readConfigAttempt = 0
        sendConfigRequests()
    }

    // MARK: - 发送

    private func sendStatusRequest() {
        guard let p = peripheral, let c = characteristic else { return }
        let frame = AntBmsCommand.requestStatus()
        p.writeValue(frame, for: c, type: .withoutResponse)
    }

    /// 依次读所有配置寄存器
    private func sendConfigRequests() {
        let reqs = AntBmsCommand.allConfigRequests()
        for (i, r) in reqs.enumerated() {
            // 每条间隔 120ms，避免一次性写爆 BMS 的接收缓冲
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) { [weak self] in
                guard let self = self,
                      let pp = self.peripheral,
                      let cc = self.characteristic else { return }
                let frame = AntBmsCommand.readRegister(r.address, length: r.length)
                pp.writeValue(frame, for: cc, type: .withoutResponse)
            }
        }
        // 3.5 秒后检查读到了几个
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self else { return }
            let total = AntBmsCommand.allConfigRequests().count
            if self.bmsConfig.isEmpty {
                self.configError = "BMS 没有回应配置读取请求（指令格式可能不对）"
            } else if self.bmsConfig.loadedFields.count < total {
                self.configError = "部分参数没读到（\(self.bmsConfig.loadedFields.count)/\(total)）"
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sendStatusRequest()
        }
        if let t = pollTimer {
            RunLoop.current.add(t, forMode: .common)
        }
        // 立刻先发一次
        sendStatusRequest()
    }

    // MARK: - 收帧

    private func feed(_ bytes: [UInt8]) {
        responseBuffer.append(contentsOf: bytes)

        // 从缓冲区里切出完整的帧
        while true {
            // 找帧头
            guard let start = responseBuffer.firstIndex(of: AntFrame.start1) else {
                responseBuffer.removeAll()
                return
            }
            if start > 0 {
                responseBuffer.removeFirst(start)
            }
            guard responseBuffer.count >= 10 else { return }

            // 找帧尾 AA 55，且前面有 CRC
            var frameEnd: Int?
            var i = 8
            while i + 1 < responseBuffer.count {
                if responseBuffer[i] == AntFrame.end1 && responseBuffer[i + 1] == AntFrame.end2 {
                    frameEnd = i + 2
                    break
                }
                i += 1
            }
            guard let end = frameEnd else {
                // 还没收完
                if responseBuffer.count > 200 { responseBuffer.removeAll() }
                return
            }

            let frame = Array(responseBuffer[0..<end])
            responseBuffer.removeFirst(end)
            handle(frame)
        }
    }

    private func handle(_ frame: [UInt8]) {
        // 记录原始帧，方便排查
        rawFrameHex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        framesReceived += 1
        lastResponseAt = Date()

        // 只校验帧头帧尾，不强求 CRC
        // 官方 App 也是这么干的：startsWith("7ea1") && endsWith("aa55")
        // BMS 回帧的 CRC 算法和请求帧可能不同，硬校验会把好帧全丢掉
        guard frame.count >= 10,
              frame[0] == AntFrame.start1,
              frame[1] == AntFrame.start2,
              frame[frame.count - 2] == AntFrame.end1,
              frame[frame.count - 1] == AntFrame.end2 else {
            errorMsg = "收到不完整或格式不对的帧"
            return
        }
        // CRC 只做记录，不用来拦数据
        let crcOK = AntBmsCommand.verify(frame)
        if !crcOK {
            // 不报错，只是内部标记
            configError = nil
        }

        errorMsg = nil
        if decoder.process(frame) {
            data = decoder.data
            // 先记电流（电压记录要用到平滑电流判断是否在充电）
            recordCurrent(decoder.data.current)
            recordVoltage(avgCellVoltage)
            // 同步配置（读到了就更新）
            if decoder.config != bmsConfig {
                bmsConfig = decoder.config
                if !bmsConfig.isEmpty {
                    configError = nil
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension AntBmsManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            errorMsg = "蓝牙未开启或无权限"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        // 蚂蚁 BMS 通常叫 ANT-xxx / ANT@xxx
        let looksLikeAnt = name.uppercased().contains("ANT")
        // 已经连过的优先显示
        if discovered.contains(where: { $0.id == peripheral.identifier }) { return }
        discovered.append((id: peripheral.identifier, name: name.isEmpty ? "(未命名设备)" : name, rssi: RSSI.intValue))
        _ = looksLikeAnt
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        errorMsg = nil
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connected = false
        errorMsg = "连接失败：\(error?.localizedDescription ?? "未知")"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connected = false
        characteristic = nil
        pollTimer?.invalidate()
        pollTimer = nil
        errorMsg = "已断开"
    }
}

// MARK: - CBPeripheralDelegate

extension AntBmsManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            errorMsg = "设备没有服务"
            return
        }
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }

        for c in chars {
            // 优先 FFE1
            if c.uuid == AntBmsBLE.characteristicUUID {
                characteristic = c
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
                startPolling()
                // 连上就自动读一次配置（过压保护、容量等）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.readConfigAttempt = 0
                    self?.sendConfigRequests()
                }
                return
            }
        }
        // 没有 FFE1 就找第一个支持 notify 的
        if characteristic == nil {
            if let c = chars.first(where: { $0.properties.contains(.notify) }) {
                characteristic = c
                peripheral.setNotifyValue(true, for: c)
                startPolling()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.readConfigAttempt = 0
                    self?.sendConfigRequests()
                }
            } else {
                errorMsg = "没有可用的特征（找不到 FFE1）"
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let v = characteristic.value else { return }
        feed([UInt8](v))
    }
}
