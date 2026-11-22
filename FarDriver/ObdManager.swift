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

    /// 把「不支持的 PID」集合转成可显示的命令字符串列表
    private func refreshUnsupportedList() {
        var list: [String] = []
        for p in ObdPid.allCases where unsupported.contains(p) {
            list.append(p.command)
        }
        unsupportedPids = list
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

    /// 协议编号：0 = 自动，其它对应 ELM327 的 ATSPn
    ///
    /// 有些车自动选协议会返回 UNABLE TO CONNECT，
    /// 手动指定正确协议通常就能连上。
    static var protocolNumber: Int {
        get { UserDefaults.standard.integer(forKey: "obdProtocol") }
        set { UserDefaults.standard.set(newValue, forKey: "obdProtocol") }
    }

    /// 可选协议列表
    static let protocolOptions: [(num: Int, name: String)] = [
        (0, "自动（先试这个）"),
        (6, "CAN 11位 500k（汽油车最常见）"),
        (8, "CAN 11位 250k"),
        (7, "CAN 29位 500k"),
        (9, "CAN 29位 250k"),
        (3, "ISO 9141-2"),
        (4, "KWP 5baud"),
        (5, "KWP 快初始化"),
        (1, "SAE J1850 PWM"),
        (2, "SAE J1850 VPW"),
    ]

    // MARK: - 一键自动探测

    /// 探测是否正在进行
    @Published private(set) var scanningProtocols = false
    /// 探测结果（每行一条）
    @Published private(set) var probeResults: [String] = []
    /// 探测找到的可用协议编号（-1 表示没找到）
    @Published private(set) var foundProtocol: Int = -1

    /// 一键自动探测：把所有协议挨个试一遍
    ///
    /// 流程：
    ///   ① 读适配器信息（ATI / ATRV，确认硬件和电压）
    ///   ② 对每个协议 ATSPn + 0100，看能不能拿到 41 00 响应
    ///   ③ 找到第一个能通的就记下来，并写入设置
    func autoProbeProtocols() {
        guard ready || status == .connected || status == .initializing else {
            errorMsg = "先连上适配器再探测"
            return
        }

        scanningProtocols = true
        probeResults.removeAll()
        foundProtocol = -1

        // 探测期间停掉轮询，避免命令打架
        stopPolling()

        let testOrder: [(num: Int, name: String)] = [
            (6, "CAN 11/500"),
            (8, "CAN 11/250"),
            (7, "CAN 29/500"),
            (9, "CAN 29/250"),
            (5, "KWP 快初始化"),
            (4, "KWP 5baud"),
            (3, "ISO 9141-2"),
            (1, "J1850 PWM"),
            (2, "J1850 VPW"),
        ]

        // ① 先读硬件信息
        send("ATI", timeout: 3.0) { [weak self] b1 in
            guard let self else { return }
            let info = b1.map { ObdParser.rawString($0) } ?? "（无回应）"
            self.probeResults.append("适配器: \(info)")

            self.send("ATRV", timeout: 3.0) { [weak self] b2 in
                guard let self else { return }
                let volt = b2.map { ObdParser.rawString($0) } ?? "（无回应）"
                self.probeResults.append("电压: \(volt)")
                self.probeResults.append("─────────────")

                // ② 逐个协议测试
                self.probeNext(index: 0, list: testOrder)
            }
        }
    }

    /// 递归测下一个协议
    private func probeNext(index: Int, list: [(num: Int, name: String)]) {
        guard index < list.count else {
            scanningProtocols = false

            if foundProtocol >= 0 {
                probeResults.append("")
                probeResults.append("✅ 找到可用协议：\(foundProtocol)")
                Self.protocolNumber = foundProtocol
                probeResults.append("正在切回协议 \(foundProtocol)…")

                // ⚠️ 关键：探测结束时适配器还停在**最后一个试过的协议**上（比如协议 2），
                //    必须显式切回找到的那个协议，否则后续全是 NO DATA。
                switchbackAndStart(protocolNum: foundProtocol)
            } else {
                probeResults.append("")
                probeResults.append("❌ 所有协议都连不上车辆 ECU")
                probeResults.append("可能：点火未开 / OBD 线序问题 / 适配器不兼容此车")
                Self.protocolNumber = 0
                // 异步切回自动，不阻塞主线程（同步等待会死锁）
                self.send("ATSP0", timeout: 2.5) { [weak self] _ in
                    guard let self else { return }
                    if self.ready { self.startPolling() }
                }
            }
            return
        }

        let (num, name) = list[index]

        // 先切协议
        send("ATSP\(num)", timeout: 2.5) { [weak self] spResp in
            guard let self else { return }
            let spText = spResp.map { ObdParser.rawString($0) } ?? ""
            if spText.contains("?") {
                self.probeResults.append("协议\(num) \(name): 适配器不支持")
                self.probeNext(index: index + 1, list: list)
                return
            }

            self.send("0100", timeout: 10.0) { [weak self] data in
                guard let self else { return }

                if let data, data.contains(0x41) {
                    let hex = ObdParser.debugText(data)
                    self.probeResults.append("协议\(num) \(name): ✅ 成功 [\(hex)]")
                    if self.foundProtocol < 0 {
                        self.foundProtocol = num
                    }
                } else if let data {
                    let text = ObdParser.rawString(data)
                    if text.contains("UNABLE") || text.contains("NODATA") {
                        self.probeResults.append("协议\(num) \(name): 无响应")
                    } else {
                        self.probeResults.append("协议\(num) \(name): \(text)")
                    }
                } else {
                    self.probeResults.append("协议\(num) \(name): 超时")
                }

                self.probeNext(index: index + 1, list: list)
            }
        }
    }

    /// 切回指定协议，确认能通信后再开始轮询
    private func switchbackAndStart(protocolNum: Int) {
        send("ATSP\(protocolNum)", timeout: 2.5) { [weak self] _ in
            guard let self else { return }
            // 再确认一次协议真的生效了
            self.send("0100", timeout: 8.0) { [weak self] data in
                guard let self else { return }
                if let data, data.contains(0x41) {
                    self.probeResults.append("✅ 已切回协议 \(protocolNum)，通信正常")
                    self.errorMsg = nil
                } else {
                    self.probeResults.append("⚠️ 切回协议 \(protocolNum) 后仍无响应")
                }
                if self.ready { self.startPolling() }
            }
        }
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
    private(set) var txNeedsResponse = false
    /// 接收缓冲：BLE 会把一条响应拆包，必须攒到 '>' 才算完整
    private var rxBuffer = ""
    /// 发送队列：上一条命令没回来之前，后续命令排队等
    private var sendQueue: [(String, TimeInterval, ([UInt8]?) -> Void)] = []
    /// 已经为某个服务启动过握手（防止一个设备的多个服务重复初始化）
    private var initStarted = false
    /// 所有候选串口服务（握手失败时换下一个重试）
    private var candidateChars: [(write: CBCharacteristic, notify: CBCharacteristic?)] = []
    /// 当前试到第几个候选
    private var candidateIndex = 0

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
    /// 发送一条 ELM327 命令
    ///
    /// ⚠️ 关键：必须「等上一条响应回来或超时」才能发下一条。
    /// ELM327 是单线程串口设备，连发会丢命令——
    /// 之前握手只收到 ATZ 一条回应，就是因为后续命令被冲掉了。
    private func send(_ cmd: String, timeout: TimeInterval = 2.0,
                      completion: @escaping ([UInt8]?) -> Void) {
        guard let p = peripheral, let ch = txChar else {
            completion(nil)
            return
        }

        // 上一条还没结束 → 排队，等它完成后自动发
        if pendingCommand != nil {
            sendQueue.append((cmd, timeout, completion))
            return
        }

        pendingTimer?.invalidate()
        pendingCommand = cmd
        pendingHandler = { bytes in completion(bytes) }

        let payload = (cmd + "\r").data(using: .ascii) ?? Data()
        logTx(cmd)
        p.writeValue(payload, for: ch,
                     type: txNeedsResponse ? .withResponse : .withoutResponse)

        startPendingTimer(timeout)
    }

    /// 启动超时计时器
    private func startPendingTimer(_ timeout: TimeInterval) {
        pendingTimer?.invalidate()
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.pendingCommand != nil else { return }
            self.pendingCommand = nil
            let h = self.pendingHandler
            self.pendingHandler = nil
            h?(nil)
            self.drainSendQueue()
        }
        RunLoop.main.add(t, forMode: .common)
        pendingTimer = t
    }

    /// 从排队里取下一条发
    private func drainSendQueue() {
        guard pendingCommand == nil, !sendQueue.isEmpty else { return }
        let (cmd, t, done) = sendQueue.removeFirst()
        send(cmd, timeout: t, completion: done)
    }

    // MARK: - 初始化

    private func beginInit() {
        status = .initializing
        ready = false
        handshakeLog.removeAll()
        handshakeLog.append("开始握手")

        // 依次握手，全部完成后再开轮询
        //
        // 按 ymobd / 通用 ELM327 客户端的最佳实践调优：
        //   · ATZ 之后多等一会儿，等它真正重启完
        //   · ATE0 一定要生效（否则回显混进响应里会解析错）
        //   · ATSP0 之后给 ECU 搜索留足时间，第一次连上 ECU 可能要几秒
        let steps: [(String, TimeInterval)] = [
            ("ATZ", 3.5),      // 复位（最耗时，给足）
            ("ATE0", 1.5),     // 关回声
            ("ATL0", 1.2),     // 关换行
            ("ATS0", 1.2),     // 关空格
            // ⚠️ 不用 ATH0：实测这个适配器在关掉 CAN 头后，
            //   0100 能通但所有单个 PID 都返回 NO DATA。
            //   保持 CAN 头，解析器会自动跳过（41 前面的 7E8 之类）。
            // 协议：用户指定就用指定的，否则自动
            ("ATSP\(Self.protocolNumber)", 2.5),
            ("ATAT1", 1.5),    // 自适应计时（慢车必需）
            // 显式指定「向引擎 ECU 发」并「只收引擎 ECU 的回复」。
            // 有些车 / 适配器组合不做这一步时，0100 能通但单 PID 全 NO DATA。
            ("ATSH7E0", 1.2),
            ("ATCRA7E8", 1.2),
            ("0100", 12.0),    // 探测 ECU 是否可达
        ]

        var okCount = 0

        func run(_ index: Int) {
            guard index < steps.count else {
                // ── 握手结束：判断要不要换服务重试 ──
                if okCount == 0, candidateIndex + 1 < candidateChars.count {
                    // 这个服务完全没回应，换下一个候选
                    candidateIndex += 1
                    let next = candidateChars[candidateIndex]
                    handshakeLog.append("当前服务无回应，换下一个服务重试（\(candidateIndex + 1)/\(candidateChars.count)）")
                    if let p = peripheral {
                        txChar = next.write
                        txNeedsResponse = next.write.properties.contains(.write)
                        notifyChar = next.notify
                        p.setNotifyValue(true, for: next.notify ?? next.write)
                    }
                    // 重跑一遍握手（initStarted 保持 true，不再重复收集候选）
                    beginInit()
                    return
                }

                ready = true
                status = .connected
                unsupported.removeAll()
                handshakeLog.append("握手完成（\(okCount)/\(steps.count) 条有回应）")
                if okCount == 0 {
                    handshakeLog.append("⚠️ 所有服务都没回应，适配器可能不兼容")
                    errorMsg = "适配器没回应，试试断开重连"
                }
                startPolling()
                return
            }
            let (cmd, t) = steps[index]
            let sentAt = Date()
            send(cmd, timeout: t) { [weak self] bytes in
                guard let self else { return }
                let ms = Int(Date().timeIntervalSince(sentAt) * 1000)
                let text = (bytes.map { ObdParser.debugText($0) } ?? "")

                if let bytes, !bytes.isEmpty {
                    self.handshakeLog.append("\(cmd) → \(bytes.count)B [\(text)] (\(ms)ms)")
                    // 只有非空且不是 UNABLE TO CONNECT 才算真的通
                    if !text.contains("UNABLETOCONNECT") && !text.contains("NODATA") {
                        okCount += 1
                    }
                } else if bytes != nil {
                    self.handshakeLog.append("\(cmd) → 空 (\(ms)ms)")
                } else {
                    self.handshakeLog.append("\(cmd) → 超时 (\(ms)ms)")
                }
                run(index + 1)
            }
        }
        run(0)
    }

    // MARK: - 轮询

    /// 开始轮询
    ///
    /// 握手阶段（含 0100）已经确认过能连上 ECU，
    /// 这里**不再重复探测**——之前重复探测会把已通的协议改乱，
    /// 导致轮询全变 NO DATA。
    private func startPolling() {
        stopPolling()
        handshakeLog.append("开始轮询（协议 \(Self.protocolNumber)）")
        startPollLoop()
    }

    /// 协议探测：反复问 0100，直到能连上 ECU
    ///
    /// ELM327 首次连 ECU 要搜索协议，可能要好几秒甚至十几次重试。
    /// ymobd 能在同一台车上读到，说明车是支持的，
    /// 这里多给几次机会，避免一次 UNABLE TO CONNECT 就放弃。
    private func startPollLoop() {
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
                self.refreshUnsupportedList()
                return
            }
            if let v = ObdParser.value(bytes, pid: pid) {
                self.apply(pid: pid, value: v)
            } else {
                // 响应里没有这个 PID，也算不支持
                self.unsupported.insert(pid)
                self.refreshUnsupportedList()
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
        sendQueue.removeAll()
        initStarted = false
        candidateChars.removeAll()
        candidateIndex = 0
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

        let uuid = service.uuid.uuidString.uppercased()
        appendLog("< 服务 \(uuid) 有 \(chars.count) 个特征")

        // ── 只认已连接的串口服务，避免重复初始化 ──
        //
        // ⚠️ 这台 OBDII 有 FFF0 和 AE00 两个服务，
        //    之前每个服务的回调都会触发 beginInit()，
        //    结果握手被并发跑了好几遍，互相把 pendingCommand 覆盖掉，
        //    表现就是只有第一条 ATZ 有回应，后面全部超时。
        if ready || initStarted {
            return
        }
        initStarted = true

        // 已知的 BLE 串口特征：
        //   FFE0 → FFE1
        //   FFF0 → FFF1/FFF2   ← 这台是这种
        //   AE00 → AE01(写) / AE02(通知)  ← 这台实际用的是这个
        //   Nordic → 6E400002 / 6E400003
        let isSerial = uuid.contains("FFE0")
            || uuid.contains("FFF0")
            || uuid.contains("AE00")
            || uuid.contains("6E400001")

        var writeChar: CBCharacteristic?
        var notifChar: CBCharacteristic?

        for c in chars {
            let canWrite = c.properties.contains(.write)
                || c.properties.contains(.writeWithoutResponse)
            let canNotify = c.properties.contains(.notify)
                || c.properties.contains(.indicate)
            if canWrite, writeChar == nil { writeChar = c }
            if canNotify, notifChar == nil { notifChar = c }
        }

        // 串口服务里优先；非串口服务只在还没有 tx 时兜底
        guard let w = writeChar else { return }
        if !isSerial && txChar != nil { return }

        // 收集所有候选（握手失败时依次尝试）
        candidateChars.append((write: w, notify: notifChar))

        // 如果还没开始过握手，就用这个服务的特征起手
        if initStarted, txChar != nil {
            appendLog("< 已记录候选服务 \(uuid)，当前握手不受影响")
            return
        }

        txChar = w
        txNeedsResponse = w.properties.contains(.write)

        let target = notifChar ?? w
        notifyChar = target
        peripheral.setNotifyValue(true, for: target)

        appendLog("< 选用 写=\(w.uuid.uuidString) 通知=\(target.uuid.uuidString)")

        beginInit()
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

        // 上一条完成了，放行队列里的下一条
        drainSendQueue()
    }
}
