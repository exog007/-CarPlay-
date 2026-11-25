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
        unsupportedPids = deadCodes.sorted()
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

    // MARK: - 持久化设置（OBD2 / 摩托车 各自独立，和远驱完全分开）
    //
    // key 前缀按当前数据源区分：
    //   汽车 → obd*
    //   摩托 → moto*
    // 这样同一个 App 里，汽车适配器和摩托适配器的记忆互不干扰。

    /// 当前 OBD 系列的存储前缀（obd / moto）
    private static var storePrefix: String {
        DataSource.current.storageKey
    }

    /// 自动连接上次的适配器
    static var autoConnect: Bool {
        get {
            let key = "\(storePrefix)AutoConnect"
            // 第一次进入时默认 true（有记住的设备就连）
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "\(storePrefix)AutoConnect")
        }
    }

    /// 上次连接的适配器 ID
    static var lastDeviceID: String? {
        get { UserDefaults.standard.string(forKey: "\(storePrefix)LastID") }
        set {
            let key = "\(storePrefix)LastID"
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
    static var lastDeviceName: String? {
        get { UserDefaults.standard.string(forKey: "\(storePrefix)LastName") }
        set {
            let key = "\(storePrefix)LastName"
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
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
        get { UserDefaults.standard.bool(forKey: "\(storePrefix)IsDiesel") }
        set { UserDefaults.standard.set(newValue, forKey: "\(storePrefix)IsDiesel") }
    }

    /// 协议编号：0 = 自动，其它对应 ELM327 的 ATSPn
    ///
    /// 有些车自动选协议会返回 UNABLE TO CONNECT，
    /// 手动指定正确协议通常就能连上。
    ///
    /// 摩托车默认 5（KWP2000 快初始化），汽车默认 0（自动）。
    static var protocolNumber: Int {
        get {
            let key = "\(storePrefix)Protocol"
            let v = UserDefaults.standard.integer(forKey: key)
            let src = DataSource.current
            // 第一次进入时给不同的默认值
            if UserDefaults.standard.object(forKey: key) == nil {
                switch src {
                case .motorcycle: return 5    // 摩托：KWP2000 快初始化
                case .obdYmobd:   return 0    // ymobd：自动（它的握手就是 ATSP0）
                case .obd2:       return 0    // 标准汽车：自动
                case .fardriver:  return 0
                }
            }
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: "\(storePrefix)Protocol") }
    }

    /// 可选协议列表
    static let protocolOptions: [(num: Int, name: String)] = [
        (0, "自动（先试这个）"),
        // ── 摩托车最常用（排前面）──
        (5, "KWP2000 快初始化 ★摩托常用"),
        (4, "KWP2000 5baud 慢初始化"),
        (3, "ISO 9141-2 ★老摩托常用"),
        // ── 汽车常用 ──
        (6, "CAN 11位 500k（汽油车最常见）"),
        (8, "CAN 11位 250k"),
        (7, "CAN 29位 500k"),
        (9, "CAN 29位 250k"),
        // ── 老美系 ──
        (1, "SAE J1850 PWM"),
        (2, "SAE J1850 VPW"),
    ]

    /// 摩托车推荐协议（按顺序尝试）
    ///
    /// ISO 14230-4 KWP（协议 5 快 / 4 慢）是摩托最常用的，
    /// 其次是 ISO 9141-2（协议 3），少数进口车用 CAN。
    static let motorcycleProtocols: [Int] = [5, 4, 3, 6, 8, 7, 9]

    /// 汽车推荐协议
    static let carProtocols: [Int] = [6, 8, 7, 9, 3, 5, 4, 1, 2]

    /// 当前数据源推荐的探测顺序
    static var probeOrder: [Int] {
        DataSource.current == .motorcycle ? motorcycleProtocols : carProtocols
    }

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

        // 按数据源决定探测顺序：
        //   摩托车先试 KWP / ISO9141（串行协议）
        //   汽车先试 CAN（并行协议）
        let isMoto = DataSource.current == .motorcycle
        let testOrder: [(num: Int, name: String)] = isMoto
            ? [
                (5, "KWP2000 快初始化"),
                (4, "KWP2000 5baud"),
                (3, "ISO 9141-2"),
                (6, "CAN 11/500"),
                (8, "CAN 11/250"),
                (7, "CAN 29/500"),
                (9, "CAN 29/250"),
                (1, "J1850 PWM"),
                (2, "J1850 VPW"),
              ]
            : [
                (6, "CAN 11/500"),
                (8, "CAN 11/250"),
                (7, "CAN 29/500"),
                (9, "CAN 29/250"),
                (3, "ISO 9141-2"),
                (5, "KWP2000 快初始化"),
                (4, "KWP2000 5baud"),
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

    // MARK: - 兼容性对照实验

    /// 同一辆车，用不同的 AT 配置组合去问同一个 PID，
    /// 哪种组合能拿到真数据就用哪种。
    ///
    /// 背景：ymobd 用同一个适配器能读到数据，
    /// 说明必然存在某种可行的初始化组合，这里穷举出来。
    @Published private(set) var compatTesting = false
    @Published private(set) var compatResults: [String] = []
    @Published private(set) var winningProfile: String? = nil

    private static let compatProfiles: [(name: String, commands: [String])] = [
        ("纯净（只 E0）", []),
        ("关 CAN 头", ["ATH0"]),
        ("关 CAN 头 + 去空格", ["ATH0", "ATS0"]),
        ("保留空格 ATS1", ["ATS1"]),
        ("长消息 AL", ["ATAL"]),
        ("固定 CAN11 TP6", ["ATTP6"]),
        ("功能寻址 7DF", ["ATSH7DF"]),
        ("关自适应 AT0", ["ATAT0"]),
        ("清过滤 + 慢超时", ["ATAR", "ATST96"]),
    ]

    func runCompatTest() {
        guard status == .connected || ready else {
            errorMsg = "先连上适配器"
            return
        }
        compatTesting = true
        compatResults.removeAll()
        winningProfile = nil
        stopPolling()
        runCompat(index: 0)
    }

    private func runCompat(index: Int) {
        guard index < Self.compatProfiles.count else {
            compatTesting = false
            compatResults.append("")
            if let w = winningProfile {
                compatResults.append("✅ 可用配置：\(w)")
            } else {
                compatResults.append("❌ 所有配置都拿不到单 PID 数据")
            }
            if ready { startPolling() }
            return
        }

        let profile = Self.compatProfiles[index]
        compatResults.append("—— \(profile.name) ——")

        send("ATZ", timeout: 3.5) { [weak self] _ in
            guard let self else { return }
            self.send("ATE0", timeout: 1.2) { [weak self] _ in
                guard let self else { return }
                self.applyCompat(profile, index: index, at: 0)
            }
        }
    }

    private func applyCompat(_ profile: (name: String, commands: [String]),
                             index: Int, at i: Int) {
        guard i < profile.commands.count else {
            // 应用完配置，固定协议 6 再问
            send("ATSP6", timeout: 2.0) { [weak self] _ in
                guard let self else { return }
                self.send("0100", timeout: 8.0) { [weak self] d0 in
                    guard let self else { return }
                    let ok0 = d0?.contains(0x41) ?? false
                    self.send("010C", timeout: 8.0) { [weak self] d in
                        guard let self else { return }
                        let okC = d?.contains(0x41) ?? false
                        if okC, let d {
                            self.compatResults.append("  0100 有响应, 010C ✅ [\(ObdParser.debugText(d))]")
                            if self.winningProfile == nil { self.winningProfile = profile.name }
                        } else {
                            self.compatResults.append("  0100 \(ok0 ? "有" : "无"), 010C 无响应")
                        }
                        self.runCompat(index: index + 1)
                    }
                }
            }
            return
        }

        let cmd = profile.commands[i]
        send(cmd, timeout: 1.5) { [weak self] r in
            guard let self else { return }
            let txt = r.map { ObdParser.rawString($0) } ?? ""
            self.compatResults.append("  \(cmd) → \(txt.isEmpty ? "OK" : txt)")
            self.applyCompat(profile, index: index, at: i + 1)
        }
    }

    /// 单 PID 诊断：把每条指令的原始字节都打出来
    ///
    /// 用来回答「为什么 0100 能通但 010C 不通」。
    /// 会依次发：
    ///   ATDPN（当前协议号）
    ///   ATDP（协议名）
    ///   ATH1 + 0100（带 CAN 头的 PID 列表，能看到来自哪个 ECU）
    ///   ATH1 + 010C（带 CAN 头的转速）
    ///   010C 用不同地址重试
    @Published private(set) var diagRunning = false
    @Published private(set) var diagResults: [String] = []

    func runSinglePidDiag() {
        guard status == .connected || ready else {
            errorMsg = "先连上适配器"
            return
        }
        diagRunning = true
        diagResults.removeAll()
        stopPolling()

        let cmds: [(String, TimeInterval)] = [
            // ── ① 基本状态 ──
            ("ATI", 2.0),        // 版本
            ("ATDPN", 2.0),      // 协议号
            ("ATDP", 2.0),       // 协议名
            ("ATRV", 2.0),       // 电压

            // ── ② 关键：确认 0100 和 010C 的差异 ──
            ("0100", 8.0),
            ("010C", 8.0),

            // ── ③ 试「PID 0C 但格式不同」 ──
            ("010C1", 6.0),      // 带附加参数
            ("01 0C", 6.0),      // 带空格

            // ── ④ 试其它常用 PID，看是不是全都不行 ──
            ("0101", 6.0),       // 就绪状态（简单 1 字节）
            ("0103", 6.0),       // 燃油系统状态
            ("011C", 6.0),       // OBD 标准

            // ── ⑤ 头部/过滤 相关 ──
            ("ATH1", 1.2),
            ("0100", 8.0),       // 带头看 0100 来自哪个地址
            ("010C", 8.0),       // 带头看 010C

            // ── ⑥ CAN 专用配置（可能克隆版需要显式设置）──
            ("ATCFC1", 1.5),     // 打开流控
            ("ATCAF1", 1.5),     // 打开自动格式化
            ("010C", 8.0),

            ("ATCFC0", 1.5),
            ("ATCAF0", 1.5),
            ("010C", 8.0),

            // ── ⑦ 地址扫描 ──
            ("ATCAF1", 1.2),
            ("ATSH7E0", 1.2),
            ("010C", 6.0),
            ("ATSH7E8", 1.2),
            ("010C", 6.0),
            ("ATSH7DF", 1.2),
            ("010C", 6.0),

            // ── ⑧ 恢复 ──
            ("ATSH", 1.2),
            ("ATCRA", 1.2),
            ("ATCAF1", 1.2),
            ("ATCFC1", 1.2),
        ]

        runDiag(cmds, at: 0)
    }

    private func runDiag(_ cmds: [(String, TimeInterval)], at i: Int) {
        guard i < cmds.count else {
            diagRunning = false
            diagResults.append("————— 诊断结束 —————")
            if ready { startPolling() }
            return
        }
        let (cmd, t) = cmds[i]
        send(cmd, timeout: t) { [weak self] bytes in
            guard let self else { return }
            if let bytes, !bytes.isEmpty {
                let hex = bytes.prefix(30).map { String(format: "%02X", $0) }.joined(separator: " ")
                let ascii = ObdParser.rawString(bytes)
                self.diagResults.append("\(cmd) → [\(hex)]  \(ascii)")
            } else if bytes != nil {
                self.diagResults.append("\(cmd) → (空)")
            } else {
                self.diagResults.append("\(cmd) → 超时")
            }
            self.runDiag(cmds, at: i + 1)
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
    ///
    /// 汽车默认 50L，摩托默认 15L。
    static var tankLitres: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "\(storePrefix)TankLitres")
            if v > 0 { return v }
            return DataSource.current == .motorcycle ? 15 : 50
        }
        set { UserDefaults.standard.set(newValue, forKey: "\(storePrefix)TankLitres") }
    }

    /// 轮询间隔（秒）
    ///
    /// 之前 0.35，加上每条 PID 1 秒超时 + 重试，24 条一轮要 20 多秒，
    /// 刷新率太低（转速 20 秒才动一次）。
    /// 现在 0.05：上一条响应一回来就立刻发下一条。
    private let pollInterval: TimeInterval = 0.05

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
    /// 本轮轮询的 PID 队列（用字符串 code，覆盖 ObdPidTable 全部 91 个）
    private var pollQueue: [String] = []
    private var currentPollPid: String?


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

    // MARK: - AT+CRYPT 授权握手
    //
    // 从 ymobd 反编译还原：
    //   getRndHexStr() = int2hexStr(floor(1842063751 * random) + 305419896)
    //   发 "AT+CRYPT<8位十六进制>"，适配器回 "+CRYPT:XXXXXXXX"
    //   用 edesEnCrypt(原始值) 算期望值，相等说明是正版适配器

    /// 生成 ymobd 用的随机十六进制串
    static func randomCryptHex() -> String {
        let v = Int(floor(1_842_063_751.0 * Double.random(in: 0..<1))) + 305_419_896
        return int2hexStr(v)
    }

    /// 整数转十六进制字符串（等价于 ymobd 的 int2hexStr）
    static func int2hexStr(_ v: Int) -> String {
        let u = UInt32(truncatingIfNeeded: v)
        return String(format: "%08X", u)
    }

    /// 还原 ymobd 的 EDesEn_Crypt，用于验证适配器是否正版
    static func edesEnCrypt(_ t: Int, key a: Int = 641_571_454) -> Int {
        let tt = UInt32(truncatingIfNeeded: t)
        let aa = UInt32(truncatingIfNeeded: a)
        let n = tt & 255
        let i = (tt >> 8) & 255
        let o = (tt >> 16) & 255
        let r = (tt >> 24) & 255

        let s = (o >> (n / 50)) | ((i << 2) ^ (aa << (r / 12)))
        let d = (n >> (i / 63)) | ((aa << (r / 11)) ^ (o >> 1))
        let l = (n >> (i / 46)) | ((aa << (n / 34)) ^ r)
        let m = (i << (r / 35)) | (((aa << (n / 49)) & (aa >> 18)))

        let cc = ((m << 24) & 0xFF00_0000)
               | ((l << 16) & 0x00FF_0000)
               | ((d << 8) & 0x0000_FF00)
               | (s & 0x0000_00FF)
        return Int(cc)
    }

    /// 适配器 AT+VERSION 报出来的 crypt 值（如 "6CCA5477"）
    private var adapterCrypt: String? = nil
    /// 适配器型号（如 "B02-Z"）
    private var adapterDeviceType: String? = nil

    /// 最近一次 AT+CRYPT 的验证结果（调试面板显示用）
    @Published private(set) var cryptVerified: Bool? = nil

    /// 解析 AT+VERSION 的响应，提取 device type 和 crypt
    ///
    /// 响应形如：
    ///   Shenzhen Yuming Electronics Co., Ltd.
    ///   version:V1.0.0
    ///   device type:B02-Z
    ///   device name:OBDII
    ///   device mac:A4:44:08:05:29:11
    ///   interface:v2.1
    ///   cust id:NONE
    ///   crypt:6CCA5477
    private func parseVersionInfo(_ text: String) {
        func field(_ key: String) -> String? {
            let lower = text.lowercased()
            let k = key.lowercased()
            guard let r = lower.range(of: k + ":") else { return nil }
            let rest = text[r.upperBound...]
            let line = rest.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
            let v = line.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        if let dt = field("device type") {
            adapterDeviceType = dt
            handshakeLog.append("适配器型号: \(dt)")
        }
        if let c = field("crypt") {
            adapterCrypt = c
            handshakeLog.append("适配器 crypt: \(c)")
            // 立刻算一下要发的 SETCRYPT 值，方便调试
            if let raw = UInt32(c, radix: 16) {
                let enc = Int(Self.edesEnCrypt(Int(raw)))
                handshakeLog.append("将发 AT+SETCRYPT\(String(format: "%08X", enc))")
            }
        }
    }

    /// 处理 AT+CRYPT 的响应，判断适配器是不是正版
    private func checkCryptResponse(command: String, bytes: [UInt8]) {
        let text = ObdParser.rawString(bytes).uppercased()
        // 响应里应当有 "CRYPT:XXXXXXXX"
        guard let range = text.range(of: "CRYPT:") else {
            cryptVerified = false
            handshakeLog.append("AT+CRYPT → 没看到 CRYPT 响应")
            return
        }
        let after = text[range.upperBound...]
        let code = String(after.prefix(8))
        guard code.count == 8 else {
            cryptVerified = false
            handshakeLog.append("AT+CRYPT → 响应长度不对 [\(code)]")
            return
        }
        // 取出我们发出去的随机值
        let sent = String(command.dropFirst("AT+CRYPT".count))
        guard let sentVal = UInt32(sent, radix: 16) else {
            cryptVerified = false
            return
        }
        let expect = Self.int2hexStr(Self.edesEnCrypt(Int(sentVal)))
        let ok = (code == expect)
        cryptVerified = ok
        handshakeLog.append("AT+CRYPT → 发送 \(sent) 期望 \(expect) 返回 \(code) → \(ok ? "正版✓" : "非正版✗")")
    }

    // MARK: - BLE 诊断（列特征 / 手动选择 / 多格式发送）

    /// 一个特征的信息（诊断页展示用）
    struct CharInfo: Identifiable {
        let id: String
        let serviceUUID: String
        let uuid: String
        let properties: [String]
        let canWrite: Bool
        let canNotify: Bool
        let isWriteSelected: Bool
        let isNotifySelected: Bool
    }

    /// 已发现的所有特征
    @Published private(set) var charList: [CharInfo] = []

    /// 保存所有已发现的服务和特征，供诊断页使用
    private var allServices: [CBService] = []

    /// 重新扫描服务并刷新特征列表
    func dumpCharacteristics() {
        buildCharList()
        // 如果还没发现服务，主动去发现
        if allServices.isEmpty, let p = peripheral {
            p.discoverServices(nil)
        }
    }

    private func buildCharList() {
        var out: [CharInfo] = []
        for s in allServices {
            guard let chars = s.characteristics else { continue }
            for c in chars {
                var props: [String] = []
                if c.properties.contains(.read) { props.append("read") }
                if c.properties.contains(.write) { props.append("write") }
                if c.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
                if c.properties.contains(.notify) { props.append("notify") }
                if c.properties.contains(.indicate) { props.append("indicate") }

                out.append(CharInfo(
                    id: c.uuid.uuidString,
                    serviceUUID: s.uuid.uuidString,
                    uuid: c.uuid.uuidString,
                    properties: props,
                    canWrite: c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse),
                    canNotify: c.properties.contains(.notify) || c.properties.contains(.indicate),
                    isWriteSelected: txChar?.uuid == c.uuid,
                    isNotifySelected: notifyChar?.uuid == c.uuid
                ))
            }
        }
        charList = out
    }

    /// 手动指定写特征
    func selectWrite(uuid: String) {
        for s in allServices {
            for c in s.characteristics ?? [] where c.uuid.uuidString == uuid {
                txChar = c
                txNeedsResponse = c.properties.contains(.write)
                appendLog("< 手动切换写特征为 \(uuid)")
                buildCharList()
                return
            }
        }
        errorMsg = "找不到特征 \(uuid)"
    }

    /// 手动指定通知特征并订阅
    func selectNotify(uuid: String) {
        for s in allServices {
            for c in s.characteristics ?? [] where c.uuid.uuidString == uuid {
                notifyChar = c
                peripheral?.setNotifyValue(true, for: c)
                appendLog("< 手动订阅通知特征 \(uuid)")
                buildCharList()
                return
            }
        }
        errorMsg = "找不到特征 \(uuid)"
    }

    /// 清空接收计数
    func resetRxStats() {
        clearSniff()
    }

    /// 诊断页发送：支持文本/十六进制，可加 \r \n
    func inspectorSend(text: String, asHex: Bool, appendCR: Bool, appendLF: Bool) {
        guard connected, let tx = txChar else {
            errorMsg = "还没连上或没选写特征"
            return
        }

        var data = Data()

        if asHex {
            let clean = text.replacingOccurrences(of: " ", with: "")
                            .replacingOccurrences(of: "0x", with: "")
                            .uppercased()
            var i = clean.startIndex
            while i < clean.endIndex {
                let n = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
                if let b = UInt8(clean[i..<n], radix: 16) { data.append(b) }
                i = n
            }
        } else {
            data = (text).data(using: .ascii) ?? Data()
        }

        if appendCR { data.append(0x0D) }
        if appendLF { data.append(0x0A) }

        guard !data.isEmpty else {
            errorMsg = "内容为空"
            return
        }

        let hexDump = [UInt8](data).map { String(format: "%02X", $0) }.joined(separator: " ")
        sniffLog.append(">>> 发送 [\(hexDump)] → \(tx.uuid.uuidString)")

        peripheral?.writeValue(data, for: tx,
                               type: txNeedsResponse ? .withResponse : .withoutResponse)

        // 给个兜底提示：如果 3 秒内没有任何回包，提示可能写特征不对
        let before = sniffByteCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if self.sniffByteCount == before {
                self.sniffLog.append("⚠️ 3 秒内没有任何回包（可能是写特征选错，或模块需要先握手）")
            }
        }
    }

    // MARK: - 抓包模式（调试用）


    /// 抓包模式：连上后**不发任何 AT 指令**，只被动接收并记录对方发的所有字节
    ///
    /// 用途：分析 MTB / JBT 这类私有模块的协议结构。
    /// 开了这个模式，握手会跳过，直接进入监听。
    static var sniffMode: Bool {
        get { UserDefaults.standard.bool(forKey: "obdSniffMode") }
        set { UserDefaults.standard.set(newValue, forKey: "obdSniffMode") }
    }

    /// 抓到的原始字节（hex + ASCII）
    @Published private(set) var sniffLog: [String] = []
    /// 抓到的总字节数
    @Published private(set) var sniffByteCount: Int = 0

    private var sniffBuffer: [UInt8] = []

    /// 记录一帧收到的原始数据（抓包模式下由通知回调调用）
    private func recordSniff(_ data: Data) {
        let bytes = [UInt8](data)
        sniffByteCount += bytes.count
        sniffBuffer.append(contentsOf: bytes)

        // 攒够一批或者遇到明显边界就输出一行
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = String(bytes: bytes.map {
            ($0 >= 0x20 && $0 < 0x7F) ? $0 : 0x2E
        }, encoding: .ascii) ?? ""
        sniffLog.append("[\(bytes.count)B] \(hex)   |\(ascii)|")
        // 只留最近 300 条
        if sniffLog.count > 300 { sniffLog.removeFirst(sniffLog.count - 300) }
    }

    func clearSniff() {
        sniffLog.removeAll()
        sniffBuffer.removeAll()
        sniffByteCount = 0
    }

    /// 抓包日志的完整文本（复制用）
    func sniffDump() -> String {
        var out = "=== BLE 抓包（共 \(sniffByteCount) 字节，\(sniffLog.count) 帧）===\n"
        out += sniffLog.joined(separator: "\n")
        return out
    }

    /// 在抓包模式下主动发一条 hex（试探协议用）
    func sniffSend(hex: String) {
        guard connected, let tx = txChar else {
            errorMsg = "还没连上"
            return
        }
        let clean = hex.replacingOccurrences(of: " ", with: "")
                     .replacingOccurrences(of: "0x", with: "")
                     .uppercased()
        var bytes: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let n = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let b = UInt8(clean[i..<n], radix: 16) { bytes.append(b) }
            i = n
        }
        guard !bytes.isEmpty else {
            errorMsg = "hex 格式不对"
            return
        }
        sniffLog.append(">>> 主动发送 \(hex)")
        peripheral?.writeValue(Data(bytes), for: tx,
                               type: txNeedsResponse ? .withResponse : .withoutResponse)
    }

    // MARK: - 初始化
    private func beginInit() {
        status = .initializing
        ready = false
        handshakeLog.removeAll()
        handshakeLog.append("开始握手")
        deadCodes.removeAll()
        codeFailStreak.removeAll()
        supportedPids.removeAll()

        // 抓包模式：不发任何指令，只被动接收
        if Self.sniffMode {
            status = .connected
            ready = false          // 不轮询
            clearSniff()
            handshakeLog.append("🔍 抓包模式：不发指令，等待模块主动发包")
            handshakeLog.append("（发 AT 指令会看不到私有协议，所以这里什么都不发）")
            appendLog("< 进入抓包模式")
            return
        }

        // 依次握手，全部完成后再开轮询
        //
        // 三条路径：
        //   ① ymobd 兼容模式：ATH1 + ATSP0 + AT+CRYPT（特殊适配器）
        //   ② 标准 CAN：ATH1 + ATSPn
        //   ③ 串行协议（KWP / ISO9141）：ATH0 + ATS0 + ATAT1 + ATSPn
        //
        // KWP2000 / ISO9141 是串行协议，没有 CAN 头概念，
        // 发 ATH1 反而会让响应多出字节，解析容易错位。
        let src = DataSource.current
        let isYmobd = src.usesYmobdHandshake
        let proto = Self.protocolNumber
        let isSerial = (proto == 3 || proto == 4 || proto == 5 || proto == 1 || proto == 2)

        var steps: [(String, TimeInterval)] = [
            ("ATZ", 3.5),
            ("ATE0", 1.5),
            ("ATL0", 1.2),
        ]

        if isYmobd {
            // ── ymobd 兼容模式 ──
            // 照搬 ymobd 的序列：ATH1 保持 CAN 头
            steps.append(("ATH1", 1.2))
            // 用户在设置里指定了协议就用指定的，否则 ATSP0 自动选
            if proto == 0 {
                steps.append(("ATSP0", 3.0))
            } else {
                steps.append(("ATSP\(proto)", 3.0))
            }
            steps.append(("AT+VERSION", 1.5))
            steps.append(("ATI", 1.2))
            steps.append(("ATRV", 1.2))
            // 占位：真正要发什么要等 AT+VERSION 回来后才知道
            //   · 有 crypt 字段 → AT+SETCRYPT<加密值>
            //   · 没有         → AT+CRYPT<随机值>（老的验证方式）
            steps.append(("@@CRYPT@@", 2.5))
        } else if isSerial {
            // ── 串行协议（KWP / ISO9141 / J1850）──
            steps.append(("ATH0", 1.2))     // 关 CAN 头（串行协议不需要）
            steps.append(("ATS0", 1.2))     // 关空格，简化解析
            steps.append(("ATAT1", 1.5))    // 自适应计时，慢 ECU 必需
            steps.append(("ATSP\(proto)", 3.0))
            steps.append(("ATI", 1.5))
            steps.append(("ATRV", 1.2))
        } else {
            // ── 标准 CAN ──
            steps.append(("ATH1", 1.2))     // 保持 CAN 头
            steps.append(("ATSP\(proto)", 3.0))
            steps.append(("ATI", 1.5))
            steps.append(("ATRV", 1.2))
        }

        steps.append(("0100", 12.0))

        // ymobd 在 0100 之后还会发一串查询，让适配器/ECU 进入工作状态
        // （实测：只发 0100 时后续单 PID 全是 NO DATA）
        if isYmobd {
            steps.append(("020000", 3.0))
            steps.append(("0600", 3.0))
            steps.append(("0900", 3.0))
            steps.append(("ATDP", 2.0))
            steps.append(("0120", 3.0))
            steps.append(("0140", 3.0))
        }

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
                handshakeLog.append("握手完成（\(okCount)/\(steps.count) 条有回应）")

                // ⭐ 关键：0100 没解析出 PID 就补读一次
                //    SETCRYPT 解锁后第一次 0100 经常超时（实测 7 秒以上），
                //    但之后 0120/0140 都能通，说明只是第一次握手慢。
                if supportedCodes.isEmpty {
                    handshakeLog.append("0100 没拿到位图，补读一次…")
                    send("0100", timeout: 8.0) { [weak self] b in
                        guard let self else { return }
                        if let b, !b.isEmpty {
                            self.parseSupportedMap(b)
                            self.handshakeLog.append("补读 0100 成功，支持 \(self.supportedCodes.count) 个 PID")
                        } else {
                            self.handshakeLog.append("补读 0100 也失败，用全表轮询")
                        }
                        self.startPolling()
                    }
                    return
                }
                if okCount == 0 {
                    handshakeLog.append("⚠️ 所有服务都没回应，适配器可能不兼容")
                    errorMsg = "适配器没回应，试试断开重连"
                }
                startPolling()
                return
            }
            var (cmd, t) = steps[index]
            // 动态展开加密握手指令
            if cmd.hasPrefix("@@CRYPT@@") {
                if let c = adapterCrypt, !c.isEmpty, let raw = UInt32(c, radix: 16) {
                    let enc = Int(Self.edesEnCrypt(Int(raw)))
                    cmd = "AT+SETCRYPT" + String(format: "%08X", enc)
                    handshakeLog.append("适配器型号 \(adapterDeviceType ?? "?")，crypt=\(c) → 发 SETCRYPT")
                } else {
                    cmd = "AT+CRYPT" + Self.randomCryptHex()
                }
            }
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
                    // AT+VERSION：解析 device type 和 crypt
                    if cmd == "AT+VERSION" {
                        self.parseVersionInfo(text)
                    }
                    // AT+CRYPT / AT+SETCRYPT 的返回单独校验
                    if cmd.hasPrefix("AT+CRYPT") || cmd.hasPrefix("AT+SETCRYPT") {
                        self.checkCryptResponse(command: cmd, bytes: bytes)
                    }
                    // 0100 返回的是支持 PID 位图，解析出来只问支持的
                    if cmd == "0100" {
                        self.parseSupportedMap(bytes)
                        if self.supportedCodes.isEmpty {
                            self.handshakeLog.append("⚠️ 0100 有响应但没解析出支持的 PID")
                            self.handshakeLog.append("   原始：\(text)")
                        }
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
        let src = DataSource.current.shortTitle
        handshakeLog.append("开始轮询（数据源=\(src) 协议=\(Self.protocolNumber)）")
        handshakeLog.append("支持 \(supportedCodes.count) 个 PID")
        startPollLoop()
    }

    /// 协议探测：反复问 0100，直到能连上 ECU
    ///
    /// ELM327 首次连 ECU 要搜索协议，可能要好几秒甚至十几次重试。
    /// ymobd 能在同一台车上读到，说明车是支持的，
    /// 这里多给几次机会，避免一次 UNABLE TO CONNECT 就放弃。
    private func startPollLoop() {
        // 不再用固定间隔定时器驱动——改成「响应一到立刻发下一条」的流水线，
        // 这样才能把适配器的往返时间压到最低。
        pollPump()
    }

    /// 轮询泵：上一条一结束就立刻发下一条
    ///
    /// 真正「一有响应就发下一条」，把适配器往返时间压到最低。
    private func pollPump() {
        guard ready, connected else { return }
        guard pendingCommand == nil else { return }

        if pollQueue.isEmpty {
            pollQueue = buildPollCycle()
        }
        guard !pollQueue.isEmpty else { return }

        let code = pollQueue.removeFirst()
        currentPollPid = code

        requestCode(code, attempt: 0)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingCommand = nil
        pendingHandler = nil
        currentPollPid = nil
        pollQueue.removeAll()
    }

    private func pollNext() {
        pollPump()
    }

    /// 轮询轮次计数
    private var pollRound = 0

    /// 车支持的全部 PID code（从 0100 / 0120 / 0140 位图解析）
    @Published private(set) var supportedCodes: Set<String> = []

    /// 是否全量轮询
    ///
    ///   false（默认）：只轮询仪表要用的 7 项，刷新最快
    ///   true          ：轮询全部支持的 PID，给数据网格用
    ///
    /// 竞技仪表只显示 7 项，没必要为了后台数据拖慢刷新率。
    /// 打开 OBD2 数据页时置 true，关掉时恢复 false。
    @Published var fullPolling: Bool = false {
        didSet {
            guard oldValue != fullPolling else { return }
            // 立刻清空队列，让新策略马上生效
            pollQueue.removeAll()
            pollRound = 0
        }
    }

    /// 已知读不到的 PID code（连续失败后加入，轮询时跳过）
    private var deadCodes: Set<String> = []
    /// 每个 code 连续失败了几轮
    private var codeFailStreak: [String: Int] = [:]

    /// 组装一轮轮询
    ///
    /// 策略：
    ///   · 第 1 轮：只问仪表要用的（dashCodes），让六格立刻填满
    ///   · 第 2 轮起：仪表项的每条都问（保证实时），
    ///     其余支持的 PID 分 4 组轮转（把能读的全收上来）
    /// 每个 code 上次读取成功的时间
    private var lastReadAt: [String: Date] = [:]

    /// 各优先级的最小刷新间隔（秒）
    ///
    ///   · 转速：最快，每轮都问
    ///   · 车速：次优先，约 0.4 秒
    ///   · 其余仪表项：1~3 秒
    ///   · 后台数据（全量模式）：5 秒
    private enum PidPriority {
        static let rpmCode = "010C"
        static let speedCode = "010D"

        /// 是否要问 OBD 车速
        ///
        /// 摩托车固定用 GPS：
        ///   · 很多摩托 ECU 不上报 010D
        ///   · KWP2000 串行协议带宽紧张，省下这一条能明显提升转速刷新率
        ///   · 手机 GPS 在摩托上精度已经够用
        static var needsObdSpeed: Bool {
            DataSource.current != .motorcycle
        }

        /// 转速永远每轮问
        static let rpmInterval: TimeInterval = 0

        /// 车速间隔
        ///
        /// 摩托的 KWP2000 是串行协议，一条命令要 80~150ms，
        /// 时间片太紧会把转速拖慢，所以摩托放慢到 0.8 秒。
        static var speedInterval: TimeInterval {
            DataSource.current == .motorcycle ? 0.8 : 0.4
        }

        /// 其它仪表项（电压/水温/进气/节气门/怠速油耗）
        ///
        /// 汽车 2 秒，摩托 3 秒（摩托响应慢，给足带宽给转速）。
        static var dashInterval: TimeInterval {
            DataSource.current == .motorcycle ? 3.0 : 2.0
        }

        /// 全量模式下的后台数据
        static var extraInterval: TimeInterval {
            DataSource.current == .motorcycle ? 8.0 : 5.0
        }
    }

    /// 组装下一批要发的 PID
    ///
    /// 不再是「固定一轮问一批」，而是**按到期时间排优先级**：
    ///   ① 转速永不过期 → 每轮都发
    ///   ② 车速 0.4 秒一次
    ///   ③ 其它仪表项 2 秒一次
    ///   ④ 全量模式下后台数据 5 秒一次（分 4 组轮转，避免一次发太多）
    ///
    /// 这样转速能接近适配器极限，车速紧跟，其余 1-3 秒一刷，
    /// 不会因为后台数据把转速拖慢。
    private func buildPollCycle() -> [String] {
        func alive(_ c: String) -> Bool { !deadCodes.contains(c) }
        func due(_ c: String, _ interval: TimeInterval) -> Bool {
            guard let last = lastReadAt[c] else { return true }   // 没读过 → 立刻读
            return Date().timeIntervalSince(last) >= interval
        }

        var batch: [String] = []

        // ① 转速：永远最先发，每次都发
        if alive(PidPriority.rpmCode) {
            batch.append(PidPriority.rpmCode)
        }

        // ② 车速：到点就发（紧跟在转速后面）
        //    摩托车跳过这一条，改用 GPS 速度
        if PidPriority.needsObdSpeed,
           alive(PidPriority.speedCode),
           due(PidPriority.speedCode, PidPriority.speedInterval) {
            batch.append(PidPriority.speedCode)
        }

        // ③ 其它仪表项：2 秒一刷
        for c in Self.dashCodes {
            guard c != PidPriority.rpmCode else { continue }
            // 摩托车不问车速
            if !PidPriority.needsObdSpeed, c == PidPriority.speedCode { continue }
            guard alive(c) else { continue }
            if due(c, PidPriority.dashInterval) {
                batch.append(c)
            }
        }

        // ④ 全量模式：后台数据，5 秒一刷，每次最多 2 条（不抢转速的时间片）
        if fullPolling {
            let pool: [String]
            if supportedCodes.count >= 8 {
                pool = Self.allReadableCodes.filter { supportedCodes.contains($0) }
            } else {
                pool = Self.allReadableCodes
            }
            let dashSet = Set(Self.dashCodes)
            let extras = pool.filter { !dashSet.contains($0) && alive($0) }

            var picked = 0
            for c in extras {
                guard picked < 2 else { break }
                if due(c, PidPriority.extraInterval) {
                    batch.append(c)
                    picked += 1
                }
            }
        }

        // 全都没到期（理论上转速总在），兜底发一次转速
        if batch.isEmpty {
            batch.append(PidPriority.rpmCode)
        }

        pollRound += 1
        return batch
    }

    /// 请求一个 PID code，失败就重发（最多 2 次）
    ///
    /// 响应一到立刻驱动下一条，形成流水线。
    private func requestCode(_ code: String, attempt: Int) {
        // ymobd 模式的适配器更挑剔：重试 3 次、超时给足
        let isYmobd = DataSource.current.usesYmobdHandshake
        let maxAttempts = isYmobd ? 3 : 2
        let isLast = attempt + 1 >= maxAttempts
        let cmd = (code == "0142") ? "ATRV" : code

        let timeout: TimeInterval = isYmobd
            ? (isLast ? 1.5 : 0.8)
            : (isLast ? 1.0 : 0.5)

        send(cmd, timeout: timeout) { [weak self] bytes in
            guard let self else { return }

            // ── ATRV：文本响应 "13.2V" ──
            if code == "0142" {
                if let bytes, !bytes.isEmpty {
                    let text = ObdParser.rawString(bytes)
                    let digits = text.replacingOccurrences(of: "V", with: "")
                                      .replacingOccurrences(of: "v", with: "")
                                      .trimmingCharacters(in: .whitespaces)
                    if let v = Double(digits), v > 5, v < 30 {
                        self.reading.batteryVoltage = v
                        self.reading.updatedAt = Date()
                        ObdValueStore.shared.update(code: "0142", value: v)
                        self.codeFailStreak[code] = 0
                        self.lastReadAt[code] = Date()
                        self.pollPump()
                        return
                    }
                }
            } else if let bytes, !bytes.isEmpty,
                      let v = Self.parseAny(bytes, code: code) {
                // ── 标准 PID ──
                self.codeFailStreak[code] = 0
                self.lastReadAt[code] = Date()
                self.applyCode(code, value: v)
                ObdValueStore.shared.update(code: code, value: v)
                // 车速更新时喂给行程统计（OBD 没有功率，用发动机输出估算）
                if code == "010D" {
                    self.feedTripMeter(speed: v)
                }
                self.pollPump()
                return
            }

            // 失败：还有机会就立即重发
            if !isLast {
                self.requestCode(code, attempt: attempt + 1)
                return
            }

            // 两次都失败：累计失败轮数，连续 3 轮才永久跳过
            let streak = (self.codeFailStreak[code] ?? 0) + 1
            self.codeFailStreak[code] = streak
            // 连续 5 轮失败才永久跳过
            // SETCRYPT 刚解锁时会有几轮抖动，3 轮太急
            if streak >= 5 {
                self.deadCodes.insert(code)
                self.refreshUnsupportedList()
            }
            self.pollPump()
        }
    }

    /// 把当前车速喂给行程统计
    ///
    /// OBD 没有直接的「功率」读数，用发动机输出功率估算：
    ///   功率 ≈ 燃油消耗率(L/h) × 汽油热值(8.9 kWh/L) × 效率(0.25)
    /// 拿不到油耗时用 MAF 反推，再不行就按车速做粗略估算。
    private func feedTripMeter(speed: Double) {
        let powerW = estimatedEnginePowerW(speedKmh: speed)
        TripMeter.shared.update(speedKmh: speed, powerW: powerW)
    }

    /// 估算当前发动机输出功率（W）
    private func estimatedEnginePowerW(speedKmh: Double) -> Double {
        let store = ObdValueStore.shared

        // ① 有燃油消耗率（L/h）→ 最准
        if let rate = store.values["015E"]?.value, rate > 0 {
            // 汽油热值约 8.9 kWh/L，发动机热效率按 25%
            return rate * 8.9 * 0.25 * 1000
        }

        // ② 有空气流量（g/s）→ 按空燃比 14.7 反推
        //   汽油质量流量(g/s) = MAF / 14.7
        //   能量 = 汽油 × 43MJ/kg × 效率
        if let maf = store.values["0110"]?.value, maf > 0 {
            let fuelGps = maf / 14.7
            let fuelKgs = fuelGps / 1000.0
            // 43 MJ/kg × 0.25 效率 = 10.75 MJ/kg = 10.75 kJ/g
            let powerKW = fuelKgs * 43000.0 * 0.25
            return powerKW * 1000
        }

        // ③ 都没有：按「怠速 + 速度相关」粗略估
        //   怠速约 2kW，每 km/h 加 60W
        let idleKW = 2.0
        return (idleKW + speedKmh * 0.06) * 1000
    }

    /// 把 code 的值写入 reading
    private func applyCode(_ code: String, value: Double) {
        if let p = ObdPid(rawValue: code) {
            apply(pid: p, value: value)
            return
        }
        // 枚举外的 PID：只写进仓库，reading 不动
        reading.updatedAt = Date()
    }

    /// 车支持的 PID 集合（从 0100 / 0120 / 0140 的位图解析出来）
    ///
    /// 空集表示还没读到，此时不做过滤。
    @Published private(set) var supportedPids: Set<ObdPid> = []

    /// 解析 PID 0x00 系列返回的位图，得到这台车支持哪些 PID
    private func parseSupportedMap(_ bytes: [UInt8]) {
        // 响应形如：41 00 BE 3F A8 13（或再来一个 41 00 98 1E 80 11）
        // 每个 41 XX 后面 4 字节是位图
        var found = false
        var i = 0
        while i + 5 < bytes.count {
            guard bytes[i] == 0x41 else { i += 1; continue }

            let pidBase = Int(bytes[i + 1])
            let map = Array(bytes[(i + 2)..<(i + 6)])

            for (byteIdx, b) in map.enumerated() {
                for bit in 0..<8 where (b & (0x80 >> bit)) != 0 {
                    let pidNum = pidBase + 1 + byteIdx * 8 + bit
                    // ObdPid 的 rawValue 是 "01XX" 格式
                    let key = String(format: "01%02X", pidNum)
                    if let p = ObdPid(rawValue: key) {
                        supportedPids.insert(p)
                        found = true
                    }
                }
            }
            i += 6
        }
        // 同时用字符串 code 记录（覆盖 ObdPidTable 全部 91 个）
        let codes = Self.parseSupportedCodes(bytes)
        for c in codes { supportedCodes.insert(c) }

        if found || !codes.isEmpty {
            let all = supportedCodes.sorted().joined(separator: ",")
            handshakeLog.append("车支持 \(supportedCodes.count) 个 PID: \(all)")
        }
    }

    /// 通用解析：用 PID 表里的公式算值
    ///
    /// 比之前只支持 10 个 PID 的 switch 覆盖面大得多，
    /// 只要表里有公式就能解。
    static func parseAny(_ bytes: [UInt8], code: String) -> Double? {
        // ① 先用枚举里的专用解析（支持多字节 PID，如氧传感器 0114）
        if let p = ObdPid(rawValue: code),
           let v = ObdParser.value(bytes, pid: p) {
            return v
        }

        // ② 再退回通用表
        guard let def = ObdPidTable.def(code) else { return nil }

        let target = def.pidByte
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x41, bytes[i + 1] == target {
                let start = i + 2
                let n = def.byteCount
                guard start + n <= bytes.count else { return nil }
                let a = Double(bytes[start])
                let b = n >= 2 ? Double(bytes[start + 1]) : 0
                return def.formula(a, b)
            }
            i += 1
        }
        return nil
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

        // ── 发动机参数 ──
        case .manifoldPressure: reading.manifoldPressure = value
        case .shortFuelTrim:    reading.shortFuelTrim = value
        case .longFuelTrim:     reading.longFuelTrim = value
        case .timingAdvance:    reading.timingAdvance = value
        case .o2Sensor1:
            reading.o2Voltage = value
            // 顺便把修正值也取出来（0114 后两字节）
            if let raw = lastRawData, let trim = ObdParser.o2Trim(raw) {
                reading.o2Trim = trim
            }
        case .fuelPressure:     reading.fuelPressure = value
        case .baroPressure:     reading.barometricPressure = value
        case .runtime:          reading.runTime = value
        }
        reading.updatedAt = Date()
    }

    /// 最近一次解析所用的原始字节（给需要二次解析的 PID 用）
    private var lastRawData: [UInt8]? = nil

    /// 定期用 ATRV 读电瓶电压
    ///
    /// 很多车不支持 PID 42，但 ELM327 的 ATRV 指令永远能用，
    /// 读的是 OBD 口电压，等同于电瓶电压。
    private var voltageTick = 0

    private func pollVoltageIfNeeded() {
        voltageTick += 1
        // 每 6 轮补一次（约每 3~5 秒）
        guard voltageTick % 6 == 0 else { return }
        guard pendingCommand == nil else { return }

        send("ATRV", timeout: 1.0) { [weak self] bytes in
            guard let self else { return }
            guard let bytes, !bytes.isEmpty else { return }
            let text = ObdParser.rawString(bytes)
            // 形如 "13.2V"，取出数字
            let digits = text.replacingOccurrences(of: "V", with: "")
                              .replacingOccurrences(of: "v", with: "")
                              .trimmingCharacters(in: .whitespaces)
            if let v = Double(digits), v > 5, v < 30 {
                self.reading.batteryVoltage = v
            }
        }
    }

    // MARK: - 故障码（照搬 ymobd 的序列）

    /// 待定故障码（Mode 07，灯还没亮但已检出）
    @Published private(set) var pendingCodes: [String] = []
    /// 永久故障码（Mode 0A，清不掉）
    @Published private(set) var permanentCodes: [String] = []
    /// 上次清除是否成功
    @Published private(set) var lastClearOK: Bool? = nil
    /// 正在读取故障码（UI 显示进度用）
    @Published private(set) var dtcReading = false
    /// 正在清除故障码
    @Published private(set) var dtcClearing = false

    /// 读故障码
    ///
    /// ymobd 序列：["03","07","0A"] 连跑 3 遍
    ///   03 = 已存储的排放相关故障码
    ///   07 = 当前/待定故障码
    ///   0A = 永久故障码
    /// 跑 3 遍是因为有些车第一遍返回不完整。
    func readDtc() {
        guard ready else {
            errorMsg = "还没连接好"
            return
        }
        stopPolling()

        let isYmobd = DataSource.current.usesYmobdHandshake

        var stored = Set<String>()
        var pending = Set<String>()
        var permanent = Set<String>()

        // 读取序列按数据源区分：
        //
        // ymobd 兼容模式：03/07/0A 各跑 3 遍（它的解析有时不完整）
        // 标准 ELM327：03/07/0A 各 1 遍就够，重试反而拖慢且容易触发限制
        let queue: [String] = isYmobd
            ? ["03", "07", "0A", "03", "07", "0A", "03", "07", "0A"]
            : ["03", "07", "0A"]

        func step(_ i: Int) {
            guard i < queue.count else {
                dtcCodes = stored.sorted()
                pendingCodes = pending.sorted()
                permanentCodes = permanent.sorted()
                dtcReadAt = Date()
                dtcReading = false

                let total = stored.count + pending.count + permanent.count
                if total == 0 {
                    errorMsg = "✓ 没有故障码"
                } else {
                    errorMsg = "✓ 读到 \(total) 个（已存储 \(stored.count) / 待定 \(pending.count) / 永久 \(permanent.count)）"
                }
                if ready { startPolling() }
                return
            }
            let cmd = queue[i]
            // 标准 ELM327 给 3 秒足够；ymobd 慢一点给 5 秒
            let timeout: TimeInterval = isYmobd ? 5.0 : 3.0

            send(cmd, timeout: timeout) { [weak self] bytes in
                guard let self else { return }
                if let bytes, !bytes.isEmpty {
                    let codes = ObdParser.dtcListPlain(bytes)
                    switch cmd {
                    case "03": codes.forEach { stored.insert($0) }
                    case "07": codes.forEach { pending.insert($0) }
                    case "0A": codes.forEach { permanent.insert($0) }
                    default: break
                    }
                    self.handshakeLog.append("DTC \(cmd) → \(codes.isEmpty ? "无码" : codes.joined(separator: ","))")
                } else {
                    self.handshakeLog.append("DTC \(cmd) → 无响应")
                }
                step(i + 1)
            }
        }
        dtcReading = true
        step(0)
    }

    /// 清故障码
    ///
    /// ymobd 序列：["04","14FF0000","14FFFF00","14FFFFFF"]
    ///   04 = 标准 OBD 清除
    ///   14xxxxxx = UDS 清除指定组
    /// 两种都发，不同车只认其中一种。
    func clearDtc() {
        guard ready else {
            errorMsg = "还没连接好"
            return
        }
        stopPolling()
        lastClearOK = nil
        dtcClearing = true
        errorMsg = "正在清除…"

        let isYmobd = DataSource.current.usesYmobdHandshake

        // 清除序列按数据源区分：
        //
        // ymobd 兼容模式：04 + 3 条 UDS 服务 14（"14FF0000" 等）
        //   这是 ymobd 的做法，有些车只认 UDS 清除
        //
        // 标准 ELM327：只发 04
        //   ELM327 对 "14FF0000" 这类未定义指令会返回 "?" 或超时，
        //   反而可能让适配器进错误状态，所以标准模式只发 04。
        let queue: [(String, TimeInterval)] = isYmobd
            ? [
                ("04", 6.0),
                ("14FF0000", 6.0),
                ("14FFFF00", 6.0),
                ("14FFFFFF", 6.0),
            ]
            : [("04", 5.0)]

        var anyOK = false

        func step(_ i: Int) {
            guard i < queue.count else {
                lastClearOK = anyOK
                if anyOK {
                    // 清完立刻复查，确认真的没了
                    errorMsg = "已发送清除，正在复查…"
                    verifyCleared { [weak self] stillHas in
                        guard let self else { return }
                        if stillHas {
                            self.errorMsg = "部分故障码仍在（可能是永久码）"
                        } else {
                            self.dtcCodes.removeAll()
                            self.pendingCodes.removeAll()
                            self.permanentCodes.removeAll()
                            self.errorMsg = "✓ 故障码已清除"
                        }
                        if self.ready { self.startPolling() }
                    }
                } else {
                    errorMsg = "清除失败，这辆车可能不支持清除"
                    dtcClearing = false
                    if ready { startPolling() }
                }
                return
            }
            let (cmd, t) = queue[i]
            send(cmd, timeout: t) { [weak self] bytes in
                guard let self else { return }
                if let bytes, !bytes.isEmpty {
                    // ⚠️ 响应是**字节**不是字符串：
                    //   0x44 = Mode 04 肯定响应
                    //   0x54 = 服务 14 的肯定响应（UDS）
                    //   0x7F = 否定响应（这辆车不支持这条）
                    if bytes.contains(0x44) || bytes.contains(0x54) {
                        anyOK = true
                    }
                    if bytes.contains(0x7F) {
                        self.handshakeLog.append("\(cmd) 否定响应 [\(ObdParser.debugText(bytes))]")
                    }
                }
                step(i + 1)
            }
        }
        step(0)
    }

    /// 清除后复查：重新读 Mode 03，看还有没有码
    private func verifyCleared(completion: @escaping (Bool) -> Void) {
        send("03", timeout: 5.0) { [weak self] bytes in
            guard let self else {
                completion(false)
                return
            }
            defer { self.dtcClearing = false }
            guard let bytes, !bytes.isEmpty else {
                completion(false)   // 没响应，当作清掉了
                return
            }
            let codes = ObdParser.dtcListPlain(bytes)
            if codes.isEmpty {
                completion(false)
            } else {
                self.dtcCodes = codes
                completion(true)
            }
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
            || upper.contains("VGATE")      // Vgate iCar Pro
            || upper.contains("ICAR")
            || upper.contains("KONNWEI")
            || upper.contains("IOS-VLINK")
            || upper.contains("CARISTA")
            || upper.contains("VSCAN")
            || upper.contains("OBDLINK")
            || upper.contains("SCANTOOL")
            || upper.contains("AUTEL")
            || upper.contains("MINI")
            // 抓包用：把元征 / 京宝通等私有模块也放进来
            // 这些前缀是从 MTB APK 的字符串池里挖出来的
            || upper.contains("MTB")
            || upper.contains("JBT")
            || upper.contains("CN-OBD")
            || upper.contains("CN-HDOBD")
            || upper.contains("HONGYAN")
            || upper.contains("X431")
            || upper.contains("LAUNCH")
            || upper.contains("VCI")
            || upper.contains("DBSCAR")
            || upper.contains("EASYDIAG")

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
        ObdValueStore.shared.clear()
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
        allServices = services          // 保存给诊断页用
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

        // 优先级：
        //   ① 同时支持 write + notify 的特征（真正的串口透传，如 FFE1）
        //   ② 只支持 write 的
        var fullDuplex: CBCharacteristic?   // write + notify 都有
        var writeOnly: CBCharacteristic?

        for c in chars {
            let canWrite = c.properties.contains(.write)
                || c.properties.contains(.writeWithoutResponse)
            let canNotify = c.properties.contains(.notify)
                || c.properties.contains(.indicate)

            if canWrite && canNotify, fullDuplex == nil {
                fullDuplex = c
            }
            if canWrite && !canNotify && writeOnly == nil {
                writeOnly = c
            }
            if canNotify, notifChar == nil { notifChar = c }
        }

        // 优先用全双工特征；没有才用只写的
        writeChar = fullDuplex ?? writeOnly
        // 全双工时，通知也用同一个（发了才回）
        if let fd = fullDuplex { notifChar = fd }

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

        // 诊断页要用：刷新特征列表
        buildCharList()

        beginInit()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let d = characteristic.value, !d.isEmpty else { return }

        // 🔍 抓包模式：原样记录，不按 '>' 切帧（私有协议是二进制，没有 ASCII 结束符）
        if Self.sniffMode {
            recordSniff(d)
            return
        }

        // ── BLE 收包 ──
        //
        // ELM327 的响应格式是 "数据\r\r>"，
        // 但 BLE 会把它拆成多个包，而且**某些适配器/特征不保证带上 '>'**。
        //
        // 关键问题：如果只认 '>'，那么：
        //   ① 没收到 '>' 就一直等，超时后数据被丢弃
        //   ② 收到 '>' 但包被截断（如 "7E9 06 41 00 98 1E 80 1" 缺了最后一位）
        //
        // 改进：
        //   ① 收到 '>' 就立即完成当前响应
        //   ② 同时也接受 \r 作为结束符（有些适配器不发 '>'）
        //   ③ 如果缓冲区已有内容且长时间没新增，也当作完整（靠超时兜底）
        let chunk = String(data: d, encoding: .ascii) ?? ""
        rxBuffer += chunk

        // 有 '>' 或者 已收到 \r\r（两个回车）就当完整
        let hasPrompt = rxBuffer.contains(">")
        let hasDoubleCR = rxBuffer.contains("\r\r")

        guard hasPrompt || hasDoubleCR else {
            // 还没结束，继续等
            // 但如果 pending 已经超时，timer 会自己处理
            return
        }

        // 取出完整响应（去掉 '>' 之后的内容）
        var full = rxBuffer
        if let gtIdx = full.firstIndex(of: ">") {
            full = String(full[...gtIdx])
        }
        rxBuffer = ""

        lastRaw = full
        logRx(full)

        guard let snapshot = pendingCommand else { return }

        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingCommand = nil
        let h = pendingHandler
        pendingHandler = nil

        // AT 指令的响应是文本（"OK" / "ELM327 v1.5" / "13.2V"），
        // 不走 toBytes 解析（那个只认十六进制，会把文本变成空）。
        // 数据指令（01XX）才走 toBytes。
        let cmd = snapshot
        let bytes: [UInt8]
        if cmd.hasPrefix("AT") {
            // AT 指令：原样返回 ASCII 字节
            bytes = Array(full.utf8)
        } else {
            bytes = ObdParser.toBytes(full) ?? []
        }
        h?(bytes)

        // 上一条完成了，放行队列里的下一条
        drainSendQueue()
    }
}
