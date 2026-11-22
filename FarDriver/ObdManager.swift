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

    // MARK: - 持久化设置

    /// 自动连接上次的适配器
    static var autoConnect: Bool {
        get {
            // 第一次进入时默认 true（有记住的设备就连）
            if UserDefaults.standard.object(forKey: "obdAutoConnect") == nil { return true }
            return UserDefaults.standard.bool(forKey: "obdAutoConnect")
        }
        set { UserDefaults.standard.set(newValue, forKey: "obdAutoConnect") }
    }

    /// 上次连接的适配器
    static var lastDeviceID: String? {
        get { UserDefaults.standard.string(forKey: "obdLastID") }
        set { UserDefaults.standard.set(newValue, forKey: "obdLastID") }
    }
    static var lastDeviceName: String? {
        get { UserDefaults.standard.string(forKey: "obdLastName") }
        set { UserDefaults.standard.set(newValue, forKey: "obdLastName") }
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
        // 大多数 ELM327 支持不带响应；如果不支持也无害
        p.writeValue(payload, for: ch, type: .withoutResponse)

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

        // 依次握手，全部完成后再开轮询
        let steps: [(String, TimeInterval)] = [
            ("ATZ", 2.5),      // 复位
            ("ATE0", 1.0),     // 关回声
            ("ATL0", 1.0),     // 关换行
            ("ATS0", 1.0),     // 关空格
            ("ATH0", 1.0),     // 关 CAN 头
            ("ATSP0", 1.5),    // 自动选协议
        ]

        func run(_ index: Int) {
            guard index < steps.count else {
                // 握手完成
                ready = true
                status = .connected
                unsupported.removeAll()
                startPolling()
                return
            }
            let (cmd, t) = steps[index]
            send(cmd, timeout: t) { [weak self] _ in
                guard let self else { return }
                // AT 指令只要收到任何响应就算过，收不到也继续（有些适配器不回应）
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
                return
            }
            if let v = ObdParser.value(bytes, pid: pid) {
                self.apply(pid: pid, value: v)
            } else {
                // 响应里没有这个 PID，也算不支持
                self.unsupported.insert(pid)
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
                // 有记忆设备就直接连
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.connect(to: id)
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
        // ELM327 BLE 一般是 FFE1（写）或 Nordic UART 的 TX/RX
        for c in chars {
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                if txChar == nil {
                    txChar = c
                }
            }
        }
        if txChar != nil {
            // 找到可写特征后开始初始化
            peripheral.setNotifyValue(true, for: service.characteristics?.first(where: {
                $0.properties.contains(.notify) || $0.properties.contains(.indicate)
            }) ?? txChar!)

            beginInit()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let d = characteristic.value, !d.isEmpty else { return }

        // BLE 串口可能分包，这里累积到遇到 '>' 或 '\r' 再处理
        let text = String(data: d, encoding: .ascii) ?? ""
        lastRaw = text

        guard pendingCommand != nil else { return }

        // 有些适配器不发 '>'，收到任何内容就当响应
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingCommand = nil
        let h = pendingHandler
        pendingHandler = nil

        let bytes = ObdParser.toBytes(text) ?? []
        h?(bytes)
    }
}
