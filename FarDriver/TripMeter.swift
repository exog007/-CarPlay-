//
//  TripMeter.swift
//  行程统计 —— 按数据源分开记账
//
//  四套独立的账本：
//    · 远驱（电摩）：小计里程 + 电耗（kWh/100km）
//    · ymobd       ：小计里程 + 油耗（L/100km）
//    · 标准 OBD2   ：小计里程 + 油耗（L/100km）
//    · 摩托车      ：小计里程 + 油耗（L/100km）
//
//  每套都有自己独立的存储，互不干扰。
//  数据存在 UserDefaults，App 重启不会丢；设置里可以分别清零。
//

import Foundation
import Combine

/// 行程统计的账本类型
enum TripLedger: String, CaseIterable, Identifiable {
    /// 远驱控制器（电摩）—— 统计电耗
    case fardriver  = "fd"
    /// ymobd 兼容模式 —— 统计油耗
    case obdYmobd   = "ym"
    /// 标准 OBD2 汽车 —— 统计油耗
    case obd2       = "obd"
    /// OBD2 摩托车 —— 统计油耗
    case motorcycle = "moto"

    var id: String { rawValue }

    /// 中文名
    var title: String {
        switch self {
        case .fardriver:  return "远驱（电摩）"
        case .obdYmobd:   return "OBD2（ymobd）"
        case .obd2:       return "OBD2（标准汽车）"
        case .motorcycle: return "OBD2（摩托车）"
        }
    }

    /// 能耗单位：电耗还是油耗
    var isElectric: Bool { self == .fardriver }

    /// 能耗标签
    var consumptionLabel: String {
        isElectric ? "百公里电耗" : "百公里油耗"
    }

    /// 能耗单位
    var consumptionUnit: String {
        isElectric ? "kWh/100km" : "L/100km"
    }

    /// 累计能量标签
    var energyLabel: String {
        isElectric ? "累计电量" : "累计油量"
    }

    /// 累计能量单位
    var energyUnit: String {
        isElectric ? "kWh" : "L"
    }

    /// 从当前数据源推出该用哪个账本
    static var current: TripLedger {
        switch DataSource.current {
        case .fardriver:  return .fardriver
        case .obdYmobd:   return .obdYmobd
        case .obd2:       return .obd2
        case .motorcycle: return .motorcycle
        }
    }
}

final class TripMeter: ObservableObject {

    static let shared = TripMeter()

    // MARK: - 对外数据（当前账本的）

    /// 小计里程（km）
    @Published private(set) var distanceKm: Double = 0
    /// 累计能量：电耗模式是 kWh，油耗模式是 L
    @Published private(set) var energy: Double = 0
    /// 累计时间（秒，只统计车在动的部分）
    @Published private(set) var movingSeconds: Double = 0

    /// 平均功率（远驱）或等效功率（OBD）
    var averagePowerW: Double {
        guard movingSeconds > 1 else { return 0 }
        if ledger.isElectric {
            return energy * 1000.0 / (movingSeconds / 3600.0)
        }
        // 油耗模式：按油量折算等效功率（1 L 汽油 ≈ 8.9 kWh）
        return energy * 8.9 * 1000.0 / (movingSeconds / 3600.0)
    }

    /// 百公里能耗（电耗 kWh/100km 或油耗 L/100km）
    var consumptionPer100km: Double {
        guard distanceKm > 0.05 else { return 0 }
        return energy / distanceKm * 100.0
    }

    /// 有没有足够数据算出能耗
    var hasEnoughData: Bool {
        distanceKm > 0.05
    }

    // MARK: - 内部

    /// 当前账本
    private(set) var ledger: TripLedger = .current

    /// 单个账本的数据
    private struct Book {
        var distance: Double = 0
        var energy: Double = 0
        var seconds: Double = 0
    }

    private var books: [TripLedger: Book] = [:]

    /// 上一帧的时间戳（用来算时间差）
    private var lastTick: Date?
    /// 两次采样间隔超过这个就丢弃（比如断开重连）
    private let maxGap: TimeInterval = 3.0

    private init() {
        for l in TripLedger.allCases {
            books[l] = Book()
        }
        loadAll()
        ledger = .current
        publish()
    }

    // MARK: - 存储键

    private func keyDistance(_ l: TripLedger) -> String { "trip.\(l.rawValue).distance" }
    private func keyEnergy(_ l: TripLedger) -> String { "trip.\(l.rawValue).energy" }
    private func keySeconds(_ l: TripLedger) -> String { "trip.\(l.rawValue).seconds" }

    private func loadAll() {
        for l in TripLedger.allCases {
            var b = Book()
            b.distance = UserDefaults.standard.double(forKey: keyDistance(l))
            b.energy = UserDefaults.standard.double(forKey: keyEnergy(l))
            b.seconds = UserDefaults.standard.double(forKey: keySeconds(l))
            books[l] = b
        }
    }

    private func save(_ l: TripLedger) {
        guard let b = books[l] else { return }
        UserDefaults.standard.set(b.distance, forKey: keyDistance(l))
        UserDefaults.standard.set(b.energy, forKey: keyEnergy(l))
        UserDefaults.standard.set(b.seconds, forKey: keySeconds(l))
    }

    private func publish() {
        let b = books[ledger] ?? Book()
        distanceKm = b.distance
        energy = b.energy
        movingSeconds = b.seconds
    }

    // MARK: - 切换账本

    /// 切到指定账本
    func switchLedger(_ l: TripLedger) {
        guard l != ledger else { return }
        ledger = l
        // 切换后时间戳作废，避免把间隔算到新账本里
        lastTick = nil
        publish()
    }

    /// 跟着当前数据源自动切换
    func syncWithDataSource() {
        switchLedger(.current)
    }

    // MARK: - 采样

    /// 每收到一帧数据调用一次
    ///
    ///   speedKmh：车速
    ///   powerW  ：功率（远驱给真实 W；OBD 传等效功率 W）
    func update(speedKmh: Double, powerW: Double) {
        let now = Date()
        defer { lastTick = now }

        guard let prev = lastTick else { return }
        let dt = now.timeIntervalSince(prev)
        guard dt > 0, dt <= maxGap else { return }

        // 慢速不计里程，避免停车噪声
        guard speedKmh >= 1.0 else { return }

        var b = books[ledger] ?? Book()

        // 里程：km/h × 秒 ÷ 3600
        b.distance += speedKmh * dt / 3600.0
        b.seconds += dt

        if ledger.isElectric {
            // 电耗：W × 小时 ÷ 1000 = kWh
            // 负功率（回收）也要算，反映真实净电耗
            b.energy += powerW * dt / 3600.0 / 1000.0
        } else {
            // 油耗：等效功率 → kWh → ÷ 8.9 = 升
            if powerW > 0 {
                b.energy += powerW * dt / 3600.0 / 1000.0 / 8.9
            }
        }

        books[ledger] = b

        // 每 20 帧存一次盘
        saveCounter += 1
        if saveCounter >= 20 {
            saveCounter = 0
            save(ledger)
        }
        publish()
    }

    private var saveCounter = 0

    // MARK: - 清零

    /// 清空当前账本
    func reset() {
        reset(ledger)
    }

    /// 清空指定账本
    func reset(_ l: TripLedger) {
        books[l] = Book()
        save(l)
        if l == ledger {
            lastTick = nil
            saveCounter = 0
            publish()
        }
    }

    /// 清空全部账本
    func resetAll() {
        for l in TripLedger.allCases {
            books[l] = Book()
            save(l)
        }
        lastTick = nil
        saveCounter = 0
        publish()
    }

    // MARK: - 读取

    /// 读某个账本的原始值（设置页展示用）
    func snapshot(_ l: TripLedger) -> (distance: Double, energy: Double, seconds: Double) {
        let b = books[l] ?? Book()
        return (b.distance, b.energy, b.seconds)
    }

    /// 某账本的百公里能耗
    func consumption(_ l: TripLedger) -> Double {
        let b = books[l] ?? Book()
        guard b.distance > 0.05 else { return 0 }
        return b.energy / b.distance * 100.0
    }

    // MARK: - 显示格式化

    /// 里程文字（两位小数）
    var distanceText: String {
        String(format: "%.2f", distanceKm)
    }

    /// 能耗文字（不带单位，单位看 ledger.consumptionUnit）
    var consumptionText: String {
        guard hasEnoughData else { return "--" }
        return String(format: "%.1f", consumptionPer100km)
    }

    /// 平均功率文字（不带单位）
    var avgPowerText: String {
        guard movingSeconds > 1 else { return "--" }
        return String(format: "%.0f", averagePowerW)
    }

    /// 累计能量文字（带单位：kWh 或 L）
    var energyText: String {
        String(format: "%.3f %@", energy, ledger.energyUnit)
    }

    /// 某个账本的能量文字
    func energyText(_ l: TripLedger) -> String {
        let s = snapshot(l)
        return String(format: "%.3f %@", s.energy, l.energyUnit)
    }

    /// 某个账本的里程文字
    func distanceText(_ l: TripLedger) -> String {
        String(format: "%.2f", snapshot(l).distance)
    }

    /// 某个账本的百公里能耗文字
    func consumptionText(_ l: TripLedger) -> String {
        let c = consumption(l)
        guard c > 0 else { return "--" }
        return String(format: "%.1f", c)
    }
}
