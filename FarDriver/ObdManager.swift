//
//  ObdManager.swift
//  OBD2 / ELM327 BLE 管理器
//
//  负责：
//    ① 扫描并连接 BLE 版 ELM327（没有固定服务 UUID，靠名字 + 特征探测识别）
//    ② 初始化握手（ATZ / ATE0 / ATL0 / ATS0 / ATSP0）
//    ③ 循环轮询标准 PID
//    ④ 读故障码 / 清故障码
//
//  和 ControllerManager（远驱）互斥：设置里选哪个数据源就只启动哪个。
//

import Foundation
import CoreBluetooth
import Combine

final class ObdManager: NSObject, ObservableObject {

    static let shared = ObdManager()

    // MARK: - 发布状态

    @Published private(set) var reading = ObdReading()
    @Published private(set) var status: ConnectStatus = .idle
    @Published private(set) var deviceName = ""
    @Published private(set) var dtcCodes: [String] = []
    @Published private(set) var dtcReadAt: Date?
    @Published var errorMsg: String?

    /// 最近一次收到的原始响应（调试用）
    @Published private(set) var lastRaw = ""

    // MARK: - 调试信息（给 ObdDebugView 用）

    /// 初始化握手日志
    @Published private(set) var handshakeLog: [String] = []
    /// 收发日志（最多保留 60 条）
    @Published private(set) var txLog: [String] = []
    /// 这台车不支持的 PID
    @Published private(set) var unsupportedPids: [String] = []
    /// 发现的服务数量
    @Published private(set) var discoveredServiceCount = 0

    /// 可写特征描述
    var txCharDescription: String {
        txChar.map { "\($0.uuid.uuidString) [\($0.properties.contains(.write) ? "write " : "")\($0.properties.contains(.writeWithoutResponse) ? "writeNR " : "")]" } ?? "未找到"
    }
    /// 通知特征描述
    var notifyCharDescription: String {
        notifyChar.map { "\($0.uuid.uuidString)" } ?? "未找到"
    }

    private func logTx(_ s: String) {
        appendLog("> \(s)")
    }
    private func logRx(_ s: String) {
        let clean = s.replacingOccurrences(of: "\r", with: " ")
                       .replacingOccurrences(of: "\n", with: " ")
                       .trimmingCharacters(in: .whitespaces)
        appendLog("< \(clean)")
    }
    private func appendLog(_ s: String) {
        txLog.append(s)
        if txLog.count > 60 { txLog.removeFirst(txLog.count - 60) }
    }
    func clearLogs() {
        txLog.removeAll()
        handshakeLog.removeAll()
        unsupportedPids.removeAll()
    }

    enum ConnectStatus: Equatable {
        case idle
        case scanning
        case connecting
        case initializing
        case connected
        case disconnected
        case bluetoothOff
        case unauthorized

        var text: String {
            switch self {
            case .idle: return "未开始"
            case .scanning: return "搜索中…"
            case .connecting: return "连接中…"
            case .initializing: return "初始化…"
            case .connected: return "已连接"
            case .disconnected: return "已断开"
            case .bluetoothOff: return "蓝牙未开启"
            case .unauthorized: return "没有蓝牙权限"
            }
        }
        var isConnected: Bool { self == .connected }
    }

    // MARK: - 持久化设置（OBD2 独立记忆，和远驱完全分开）

    /// 自动连接上次的适配器
    static var autoConnect: Bool {
        get {
            // 第一次进入时默认 true（有记住的设备就连）
            if UserDefaults.standard.object(forKey: "obdAutoConnect") == nil { return true }
            return UserDefaults.standard.bool(forKey: "obdAutoConnect")
        }
        set { UserDefaults.standard.set(newValue, forKey: "obdAutoConnect") }
    }

    /// 上次连接的适配器 ID
    static var lastDeviceID: String? {
        get { UserDefaults.standard.string(forKey: "obdLastID") }
        set { UserDefaults.standard.set(newValue, forKey: "obdLastID") }
    }
    static var lastDeviceName: String? {
        get { UserDefaults.standard.string(forKey: "obdLastName") }
        set { UserDefaults.standard.set(newValue, forKey: "obdLastName") }
    }

    /// 有没有记住的设备
    static var hasRememberedDevice: Bool {
        guard let id = lastDeviceID, !id.isEmpty else { return false }
        return UUID(uuidString: id) != nil
    }

    /// 记住的设备在系统里还在不在（配对被系统清掉时返回 false）
    func rememberedDeviceAvailable() -> Bool {
        guard let idStr = Self.lastDeviceID,
              let id = UUID(uuidString: idStr) else { return false }
        return !central.retrievePeripherals(withIdentifiers: [id]).isEmpty
    }

    /// 忘掉记住的设备
    func forgetDevice() {
        Self.lastDeviceID = nil
        Self.lastDeviceName = nil
        Self.autoConnect = false
    }

    /// 已保存过、最近连接过的设备名（界面上显示用）
    var rememberedName: String {
        Self.lastDeviceName ?? "未记住设备"
    }

    /// 汽油 / 柴油（影响功率估算）
    static var isDiesel: Bool {
        get { UserDefaults.standard.bool(forKey: "obdIsDiesel") }
        set { UserDefaults.standard.set(newValue, forKey: "obdIsDiesel") }
    }

    /// 油箱容量（L），用于估算剩余油量
    static var tankLitres: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "obdTankLitres")
            return v > 0 ? v : 50
        }
        set { UserDefaults.standard.set(newValue, forKey: "obdTankLitres") }
    }

    /// 轮询间隔（秒）
    private let pollInterval: TimeInterval = 0.35

    // MARK: - 内部

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    /// 接收通知用的特征
    private var notifyChar: CBCharacteristic?
    /// 写入方式：true 用 withResponse（更可靠），false 用 withoutResponse
    private var txNeedsResponse = false
    /// 接收缓冲：BLE 会把一条响应拆包，必须攒到 '>' 才算完整
    private var rxBuffer = ""

    /// 已发现的设备（UI 列表用）
    @Published var discovered: [(id: UUID, name: String, rssi: Int)] = []
    @Published private(set) var scanning = false

    private var connected = false
    private var pollTimer: Timer?
    /// 正在等某个命令的响应
    private var pendingCommand: String?
    /// 正在等某个命令的响应
    ///
    /// 注意：内部存的是「非可选」版本，把 nil 也当成一种值传进去
    /// （超时 = 传空数组并在调用方判断），这样闭包类型简单，避免可选嵌套。
    private var pendingHandler: (([UInt8]?) -> Void)?
    private var pendingTimer: Timer?
    /// 初始化完成后才开始轮询
    private var ready = false
    /// 本轮轮询的 PID 队列
    private var pollQueue: [ObdPid] = []
    private var currentPollPid: ObdPid?
    /// 记录哪些 PID 这台车不支持，后续跳过
    private var unsupported: Set<ObdPid> = []

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 公共操作

    func startScan() {
        guard central.state == .poweredOn else {
            errorMsg = "蓝牙不可用"
            return
        }
        discovered.removeAll()

        // 先把「记住的设备」塞进列表最上面
        // 这样即使适配器当前没广播，也能直接点它连接
        if let idStr = Self.lastDeviceID,
           let id = UUID(uuidString: idStr),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            let nm = p.name ?? Self.lastDeviceName ?? "已知适配器"
            discovered.append((id: p.identifier, name: "\(nm)（已记住）", rssi: 0))
        }

        scanning = true
        status = .scanning
        errorMsg = nil
        // 没有固定服务 UUID，扫全部；允许重复上报方便看到信号变化
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        scanning = false
        if !connected { status = .idle }
    }

    func connect(to id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            errorMsg = "设备已不可用，请重新搜索"
            return
        }
        central.stopScan()
        scanning = false
        status = .connecting
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func disconnect() {
        stopPolling()
        ready = false
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    /// 手动重连上次设备
    func reconnect() {
        guard let idStr = Self.lastDeviceID, let id = UUID(uuidString: idStr) else { return }
        connect(to: id)
    }

    // MARK: - 发命令

    /// 发一条 ELM327 命令（自动加 \r），超时回调 nil
    private func send(_ cmd: String, timeout: TimeInterval = 2.0,
                      completion: @escaping ([UInt8]?) -> Void) {
        guard let p = peripheral, let ch = txChar else {
            completion(nil)
            return
        }
        pendingTimer?.invalidate()
        pendingCommand = cmd
        pendingHandler = { bytes in completion(bytes) }

        let payload = (cmd + "\r").data(using: .ascii) ?? Data()
        logTx(cmd)
        // 大多数 ELM327 支持不带响应；如果不支持也无害
        p.writeValue(payload, for: ch,
                     type: txNeedsResponse ? .withResponse : .withoutResponse)

        // 用 Timer(timeInterval:...) + RunLoop 而不是 scheduledTimer，
        // 避免 Swift 6 严格并发对 @Sendable 闭包的限制
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.pendingCommand != nil {
                self.pendingCommand = nil
                let h = self.pendingHandler
                self.pendingHandler = nil
                h?(nil)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pendingTimer = t
    }

    // MARK: - 初始化

    private func beginInit() {
        status = .initializing
        ready = false
        handshakeLog.removeAll()
        handshakeLog.append("开始握手（\(handshakeLog.isEmpty ? "新连接" : "")）")

        // 依次握手，全部完成后再开轮询
        let steps: [(String, TimeInterval)] = [
            ("ATZ", 2.5),      // 复位
            ("ATE0", 1.0),     // 关回声
            ("ATL0", 1.0),     // 关换行
            ("ATS0", 1.0),     // 关空格
            ("ATH0", 1.0),     // 关 CAN 头
            ("ATSP0", 1.5),    // 自动选协议
            ("0100", 2.0),     // 探测协议：问支持的 PID，能回应说明通了
        ]

        func run(_ index: Int) {
            guard index < steps.count else {
                ready = true
                status = .connected
                unsupported.removeAll()
                handshakeLog.append("握手完成，开始轮询")
                startPolling()
                return
            }
            let (cmd, t) = steps[index]
            let sentAt = Date()
            send(cmd, timeout: t) { [weak self] bytes in
                guard let self else { return }
                let ms = Int(Date().timeIntervalSince(sentAt) * 1000)
                if let bytes, !bytes.isEmpty {
                    self.handshakeLog.append("\(cmd) → 收到 \(bytes.count) 字节 (跳过 \(ms)ms)")
                } else if bytes != nil {
                    self.handshakeLog.append("\(cmd) → 空回应 (跳过 \(ms)ms)")
                } else {
                    self.handshakeLog.append("\(cmd) → 超时无回应 (跳过 \(ms)ms)")
                }
                // 收不到也继续（有些适配器不认某条指令）
                run(index + 1)
            }
        }
        run(0)
    }

    // MARK: - 轮询

    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollNext()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        pollNext()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingCommand = nil
        pendingHandler = nil
        currentPollPid = nil
    }

    private func pollNext() {
        guard ready, connected, pendingCommand == nil else { return }

        if pollQueue.isEmpty {
            // 开新一轮：所有支持的 PID
            pollQueue = ObdPid.allCases.filter { !unsupported.contains($0) }
        }
        guard !pollQueue.isEmpty else { return }
        let pid = pollQueue.removeFirst()
        currentPollPid = pid

        send(pid.command, timeout: 1.2) { [weak self] bytes in
            guard let self else { return }
            guard let bytes else { return }   // 超时就跳过，下个 tick 继续
            if bytes.isEmpty {
                // 这台车不支持这个 PID，记下来别再问了
                self.unsupported.insert(pid)
                self.unsupportedPids = ObdPid.allCases
                    .filter { self.unsupported.contains() }
                    .map { .command }
                return
            }
            if let v = ObdParser.value(bytes, pid: pid) {
                self.apply(pid: pid, value: v)
            } else {
                // 响应里没有这个 PID，也算不支持
                self.unsupported.insert(pid)
                self.unsupportedPids = ObdPid.allCases
                    .filter { self.unsupported.contains() }
                    .map { .command }
            }
        }
    }

    private func apply(pid: ObdPid, value: Double) {
        switch pid {
        case .rpm:        reading.rpm = value
        case .speed:      reading.speedKmh = value
        case .coolant:    reading.coolantTemp = value
        case .intakeAir:  reading.intakeTemp = value
        case .throttle:   reading.throttle = value
        case .engineLoad: reading.engineLoad = value
        case .voltage:    reading.batteryVoltage = value
        case .fuelLevel:  reading.fuelLevel = value
        case .maf:        reading.maf = value
        case .fuelRate:   reading.fuelRate = value
        case .gear:       reading.gear = Int(value)
        }
        reading.updatedAt = Date()
    }

    // MARK: - 故障码

    /// 读故障码
    func readDtc() {
        guard ready else {
            errorMsg = "还没连接好"
            return
        }
        // 读码前先停轮询，避免响应串了
        stopPolling()
        send("03", timeout: 4.0) { [weak self] bytes in
            guard let self else { return }
            if let bytes {
                self.dtcCodes = ObdParser.dtcList(bytes)
                self.dtcReadAt = Date()
                if self.dtcCodes.isEmpty {
                    self.errorMsg = "没有故障码"
                }
            } else {
                self.errorMsg = "读取失败，车辆可能不支持"
            }
            // 读完后恢复轮询
            if self.ready { self.startPolling() }
        }
    }

    /// 清故障码
    func clearDtc() {
        guard ready else {
            errorMsg = "还没连接好"
            return
        }
        stopPolling()
        send("04", timeout: 4.0) { [weak self] bytes in
            guard let self else { return }
            if bytes != nil {
                self.dtcCodes.removeAll()
                self.errorMsg = "故障码已清除"
            } else {
                self.errorMsg = "清除失败"
            }
            if self.ready { self.startPolling() }
        }
    }

    // MARK: - 派生数据（给仪表用）

    /// 显示车速：OBD2 有就用 OBD2，没有就用 GPS
    var displaySpeed: Double {
        reading.speedKmh ?? 0
    }

    /// 有没有数据
    var hasData: Bool { reading.hasAny }

    /// 估算功率 kW
    var estimatedPowerKW: Double? {
        reading.estimatedPowerKW(isDiesel: Self.isDiesel)
    }

    /// 估算剩余油量（L）
    var fuelLitres: Double? {
        guard let pct = reading.fuelLevel else { return nil }
        return Self.tankLitres * pct / 100.0
    }
}

// MARK: - CBCentralManagerDelegate

extension ObdManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if Self.autoConnect, let idStr = Self.lastDeviceID,
               let id = UUID(uuidString: idStr) {
                // 有记忆设备就直接连；连不上（适配器没开机）就退回扫描模式
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    if central.retrievePeripherals(withIdentifiers: [id]).isEmpty {
                        // 系统里已经没有这台设备，边扫边等
                        self.startScan()
                    } else {
                        self.connect(to: id)
                    }
                }
            }
        case .unauthorized:
            status = .unauthorized
        case .poweredOff:
            status = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""

        // 只收名字像 OBD 适配器的设备
        let upper = name.uppercased()
        let looksLikeObd = upper.contains("OBD")
            || upper.contains("ELM")
            || upper.contains("V-LINK")
            || upper.contains("VLINK")
            || upper.contains("VEEPEAK")
            || upper.contains("VGATE")
            || upper.contains("KONNWEI")
            || upper.contains("IOS-VLINK")
            || upper.contains("CARISTA")
            || upper.contains("VSCAN")

        // 还没连上时，优先自动连上次那台
        if !connected, peripheral.state != .connected,
           Self.autoConnect,
           let lastID = Self.lastDeviceID,
           peripheral.identifier.uuidString == lastID {
            self.peripheral = peripheral
            peripheral.delegate = self
            status = .connecting
            central.stopScan()
            scanning = false
            central.connect(peripheral, options: nil)
            return
        }

        guard looksLikeObd || !name.isEmpty else { return }

        if !discovered.contains(where: { $0.id == peripheral.identifier }) {
            discovered.append((id: peripheral.identifier,
                               name: looksLikeObd ? name : "\(name)（可能是）",
                               rssi: RSSI.intValue))
            discovered.sort { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        deviceName = peripheral.name ?? "ELM327"
        status = .initializing
        Self.lastDeviceID = peripheral.identifier.uuidString
        Self.lastDeviceName = deviceName
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connected = false
        status = .disconnected
        errorMsg = error?.localizedDescription ?? "连接失败"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connected = false
        ready = false
        txChar = nil
        notifyChar = nil
        rxBuffer = ""
        stopPolling()
        status = .disconnected
        if let e = error {
            errorMsg = e.localizedDescription
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ObdManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        discoveredServiceCount = services.count
        appendLog("< 发现 \(services.count) 个服务: " +
                  services.map { $0.uuid.uuidString }.joined(separator: ", "))
        if services.isEmpty {
            errorMsg = "这个设备没有可用的串口服务"
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

        // 常见的 BLE 串口特征 UUID：
        //   FFE0 服务 → FFE1（读写一体，最常见）
        //   Nordic UART → 6E400003(TX notify) / 6E400002(RX write)
        //   有些用 FFF0 服务 → FFF1/FFF2
        let uuid = service.uuid.uuidString.uppercased()
        let isSerialService = uuid.contains("FFE0")
            || uuid.contains("FFF0")
            || uuid.contains("6E400001")
            || uuid.contains("FF00")

        var writeChar: CBCharacteristic?
        var notifyChar: CBCharacteristic?

        for c in chars {
            let canWrite = c.properties.contains(.write)
                || c.properties.contains(.writeWithoutResponse)
            let canNotify = c.properties.contains(.notify)
                || c.properties.contains(.indicate)

            if canWrite, writeChar == nil { writeChar = c }
            if canNotify, notifyChar == nil { notifyChar = c }
        }

        // FFE1 这种读写一体的特征，既是写也是通知
        if writeChar == nil {
            // 退一步：任一可写特征
            writeChar = chars.first {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
        }

        guard let w = writeChar else {
            // 这个服务没有可写特征，等其它服务
            return
        }

        txChar = w
        // 记下写入方式：有 write 就用 withResponse 更可靠，否则用 withoutResponse
        txNeedsResponse = w.properties.contains(.write)

        // 优先用同服务的 notify 特征收数据；FFE1 自己就是
        let notifyTarget = notifyChar ?? w
        self.notifyChar = notifyTarget
        peripheral.setNotifyValue(true, for: notifyTarget)

        // 只在串口服务上启动初始化，避免在无关服务上重复触发
        if isSerialService || txChar != nil {
            beginInit()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let d = characteristic.value, !d.isEmpty else { return }

        // ── 关键：BLE 串口会把一条响应拆成多个包 ──
        //
        // 例如 "41 0C 1A F8" 可能分两次到：
        //   包1: "41 0C 1A"
        //   包2: " F8\r\r>"
        // 必须累积到 '>' 才算一条完整响应，否则只拿到半截。
        let chunk = String(data: d, encoding: .ascii) ?? ""
        rxBuffer += chunk

        // 没收到结束符就继续等
        guard rxBuffer.contains(">") else {
            // 有些适配器用 \r 结尾但不发 '>'，超时兜底也算完整
            return
        }

        // 取出完整响应，清空缓冲
        let full = rxBuffer
        rxBuffer = ""

        lastRaw = full
        logRx(full)

        guard pendingCommand != nil else { return }

        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingCommand = nil
        let h = pendingHandler
        pendingHandler = nil

        let bytes = ObdParser.toBytes(full) ?? []
        h?(bytes)
    }
}
