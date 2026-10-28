//
//  ControllerManager.swift
//  连接远驱控制器、解析数据、每 60 秒上传给本地 deepseek
//

import Foundation
import CoreBluetooth
import Combine
import WidgetKit
import ActivityKit

/// 全局共享状态
final class ControllerManager: NSObject, ObservableObject {

    static let shared = ControllerManager()

    // MARK: - 发布状态

    @Published private(set) var data = ControllerData.empty
    @Published private(set) var status: ConnectStatus = .idle
    @Published private(set) var lastUpload: Date?
    @Published private(set) var uploadError: String?
    @Published private(set) var liveActivityRunning = false
    @Published var serverBaseURL: String {
        didSet {
            UserDefaults.standard.set(serverBaseURL, forKey: "serverBaseURL")
            // 让小组件也能读到
            SharedStore.saveServerURL(serverBaseURL)
        }
    }
    /// 上传开关（持久化，App 重启后保持）
    @Published var autoUpload: Bool {
        didSet {
            UserDefaults.standard.set(autoUpload, forKey: "autoUpload")
            // 打开开关时立刻补传一次，不用干等 60 秒
            if autoUpload && !oldValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.uploadIfNeeded()
                }
            }
        }
    }
    /// 自动连接开关（持久化）
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }

    enum ConnectStatus: Equatable {
        case idle
        case scanning
        case connecting
        case connected(name: String)
        case disconnected
        case bluetoothOff
        case unauthorized

        var text: String {
            switch self {
            case .idle: return "未开始"
            case .scanning: return "搜索中…"
            case .connecting: return "连接中…"
            case .connected(let n): return "已连接 \(n)"
            case .disconnected: return "已断开"
            case .bluetoothOff: return "蓝牙未开启"
            case .unauthorized: return "没有蓝牙权限"
            }
        }
        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: - 内部

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private let decoder = FarDriverDecoder()
    private var uploadTimer: Timer?
    private var lastDeviceName: String = ""
    private var liveActivity: Activity<FarDriverAttributes>?

    private override init() {
        serverBaseURL = UserDefaults.standard.string(forKey: "serverBaseURL") ?? "http://192.168.100.101:38281"
        // 没存过就默认开
        autoUpload = UserDefaults.standard.object(forKey: "autoUpload") as? Bool ?? true
        autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        startUploadTimer()
    }

    /// 设置错误信息（给设置界面用）
    func setUploadError(_ msg: String?) {
        uploadError = msg
    }

    // MARK: - 参数查看（只读）

    /// 已经收到的帧数（用于判断参数页有没有数据）
    var receivedFrameCount: Int { decoder.frameCache.count }

    /// 帧号 → 寄存器地址
    func registerAddress(frameId: Int) -> UInt8? {
        guard frameId >= 0, frameId < FarDriverBLE.flashReadAddr.count else { return nil }
        return FarDriverBLE.flashReadAddr[frameId]
    }

    /// 取某个帧号的原始数据
    func rawFrame(_ frameId: Int) -> [UInt8]? {
        decoder.frameCache[frameId]
    }

    /// 所有已收到的帧，按帧号排序
    var allFrames: [(id: Int, address: UInt8, bytes: [UInt8])] {
        decoder.frameCache.keys.sorted().compactMap { k in
            guard let addr = registerAddress(frameId: k), let b = decoder.frameCache[k] else { return nil }
            return (k, addr, b)
        }
    }

    // MARK: - Live Activity（CarPlay 显示）

    /// 启动 Live Activity —— 启动后会自动出现在 CarPlay
    func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            uploadError = "系统没开启实时活动权限"
            return
        }
        // 已经有一个了就先结束
        if liveActivity != nil { return }

        let attrs = FarDriverAttributes(deviceName: lastDeviceName.isEmpty ? "远驱控制器" : lastDeviceName)
        let state = makeContentState()

        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
            liveActivity = try Activity.request(
                attributes: attrs,
                content: content,
                pushType: nil
            )
            liveActivityRunning = true
        } catch {
            uploadError = "启动实时活动失败：\(error.localizedDescription)"
        }
    }

    /// 结束 Live Activity
    func stopLiveActivity() {
        guard let a = liveActivity else { return }
        Task {
            await a.end(nil, dismissalPolicy: .immediate)
            await MainActor.run {
                self.liveActivity = nil
                self.liveActivityRunning = false
            }
        }
    }

    /// 把当前数据推进 Live Activity
    private func updateLiveActivity() {
        guard let a = liveActivity else { return }
        let state = makeContentState()
        Task {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
            await a.update(content)
        }
    }

    private func makeContentState() -> FarDriverAttributes.ContentState {
        FarDriverAttributes.ContentState(
            voltage: data.voltage,
            current: data.current,
            power: data.power,
            rpm: data.rpm,
            speed: data.speed,
            gear: data.gear,
            mosTemp: data.mosTemp,
            motorTemp: data.motorTemp,
            soc: data.soc,
            isRegen: data.isRegen
        )
    }

    // MARK: - 连接控制

    /// 发现的设备列表（给用户手动选）
    @Published private(set) var discovered: [(id: UUID, name: String, rssi: Int)] = []

    func startScan() {
        guard central.state == .poweredOn else {
            status = central.state == .unauthorized ? .unauthorized : .bluetoothOff
            uploadError = "蓝牙不可用，状态：\(central.state.rawValue)"
            return
        }
        discovered.removeAll()
        status = .scanning
        uploadError = nil
        // 不指定 service UUID，扫描所有设备，兼容性更好
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        // 20 秒后停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self else { return }
            if self.status == .scanning {
                self.central.stopScan()
                if self.discovered.isEmpty {
                    self.status = .disconnected
                    self.uploadError = "20 秒内没搜到任何蓝牙设备。请确认：1) 控制器已通电 2) 远驱官方 App 已完全关闭 3) 手机蓝牙已开"
                } else {
                    self.status = .idle
                }
            }
        }
    }

    /// 手动连接某个设备
    func connect(to id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            uploadError = "设备已不可用，请重新扫描"
            return
        }
        central.stopScan()
        self.peripheral = p
        p.delegate = self
        status = .connecting
        central.connect(p, options: nil)
    }

    func stopScan() {
        central.stopScan()
        if status == .scanning { status = .idle }
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        characteristic = nil
        discovered.removeAll()
        status = .disconnected
    }

    // MARK: - 上传

    private func startUploadTimer() {
        uploadTimer?.invalidate()
        uploadTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.uploadIfNeeded()
        }
        // 允许后台刷新
        RunLoop.current.add(uploadTimer!, forMode: .common)
    }

    func uploadIfNeeded() {
        guard autoUpload else { return }
        guard status.isConnected else { return }
        // 数据太旧（超过 2 分钟）就别传了
        guard Date().timeIntervalSince(data.updatedAt) < 120 else { return }
        upload()
    }

    /// 立刻上传一次（手动按钮用，不受开关限制）
    func upload() {
        guard status.isConnected else {
            uploadError = "控制器没连上，没数据可传"
            return
        }
        guard Date().timeIntervalSince(data.updatedAt) < 120 else {
            uploadError = "数据超过 2 分钟没更新，先等控制器回数据"
            return
        }

        guard let url = URL(string: serverBaseURL.trimmingCharacters(in: .whitespaces) + "/api/controller") else {
            uploadError = "服务器地址不对"
            return
        }

        var body: [String: Any] = [
            "time": Int(data.updatedAt.timeIntervalSince1970 * 1000),
            "device": lastDeviceName.isEmpty ? "FarDriver" : lastDeviceName,
            "voltage": data.voltage,
            "current": data.current,
            "rpm": data.rpm,
            "speed": data.speed,
            "gear": data.gear,
            "mosTemp": data.mosTemp,
            "motorTemp": data.motorTemp,
            "soc": data.soc,
            "power": Int(data.power.rounded()),
            "regen": data.isRegen,
        ]
        if data.voltage <= 0 { body.removeValue(forKey: "voltage") }
        if data.current == 0 { body.removeValue(forKey: "current") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.uploadError = err.localizedDescription
                } else if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    self.lastUpload = Date()
                    self.uploadError = nil
                    // 同步给小组件
                    SharedStore.save(self.data)
                    WidgetCenter.shared.reloadAllTimelines()
                } else {
                    self.uploadError = "服务器返回异常"
                }
            }
        }.resume()
    }

    /// 本地也存一份给小组件
    private func snapshot() {
        SharedStore.save(data)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - CBCentralManagerDelegate

extension ControllerManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if status == .bluetoothOff || status == .unauthorized { status = .idle }
            if autoConnect && peripheral == nil { startScan() }
        case .poweredOff:
            status = .bluetoothOff
        case .unauthorized:
            status = .unauthorized
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
            ?? "未知设备"

        // 已经记录过就跳过
        if discovered.contains(where: { $0.id == peripheral.identifier }) { return }

        // 只记录，不自动连接，由用户自己选
        discovered.append((id: peripheral.identifier, name: name, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "FarDriver"
        lastDeviceName = name
        status = .connected(name: name)
        // 连上了就清空搜索列表，界面更干净
        discovered.removeAll()
        // 发现所有服务，不限定 UUID
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        status = .disconnected
        self.peripheral = nil
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        status = .disconnected
        self.peripheral = nil
        self.characteristic = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard autoConnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.autoConnect, self.peripheral == nil else { return }
            self.startScan()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ControllerManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            uploadError = "没发现服务：\(error?.localizedDescription ?? "未知")"
            return
        }
        if services.isEmpty {
            uploadError = "设备没有任何服务，可能不是控制器"
            return
        }
        // 优先找 FFE0，找不到就遍历所有服务的特征
        var found = false
        for s in services where s.uuid == FarDriverBLE.serviceUUID {
            found = true
            peripheral.discoverCharacteristics(nil, for: s)
        }
        if !found {
            // 没有 FFE0，把所有服务都列出来（可能是别的 UUID）
            let names = services.map { $0.uuid.uuidString }.joined(separator: ", ")
            uploadError = "没找到 FFE0 服务，该设备提供：\(names)"
            for s in services {
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            // 优先 FFEC，没有就找任何支持 notify 的
            let isTarget = c.uuid == FarDriverBLE.characteristicUUID
            if isTarget || (characteristic == nil && c.properties.contains(.notify)) {
                characteristic = c
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
                if c.properties.contains(.read) {
                    peripheral.readValue(for: c)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let value = characteristic.value else { return }
        if decoder.process(value) {
            let d = decoder.data
            if d != data {
                data = d
                snapshot()
                // 同步到 CarPlay / 锁屏 / 灵动岛
                updateLiveActivity()
            }
        }
    }
}
