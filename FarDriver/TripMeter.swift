//
//  TripMeter.swift
//  小计里程 + 平均功率 + 百公里电耗
//
//  原理：
//    · 每收到一帧控制器数据，用「速度 × 时间差」累加里程
//    · 同时累加「功率 × 时间差」得到能量（kWh）
//    · 百公里电耗 = 能量 ÷ 里程 × 100
//
//  数据存在 UserDefaults，App 重启不会丢；设置里可以清零。
//

import Foundation
import Combine

final class TripMeter: ObservableObject {

    static let shared = TripMeter()

    // MARK: - 对外数据

    /// 小计里程（km）
    @Published private(set) var distanceKm: Double = 0
    /// 累计能量（kWh）
    @Published private(set) var energyKWh: Double = 0
    /// 累计时间（秒，只统计车在动的部分）
    @Published private(set) var movingSeconds: Double = 0

    /// 平均功率（W）= 能量 ÷ 时间
    var averagePowerW: Double {
        guard movingSeconds > 1 else { return 0 }
        return energyKWh * 1000.0 / (movingSeconds / 3600.0)
    }

    /// 百公里电耗（kWh/100km）
    var consumptionPer100km: Double {
        guard distanceKm > 0.05 else { return 0 }
        return energyKWh / distanceKm * 100.0
    }

    /// 有没有足够数据算出电耗
    var hasEnoughData: Bool {
        distanceKm > 0.05
    }

    // MARK: - 内部

    private let keyDistance = "tripDistanceKm"
    private let keyEnergy = "tripEnergyKWh"
    private let keySeconds = "tripMovingSeconds"

    /// 上一帧的时间戳（用来算时间差）
    private var lastTick: Date?
    /// 两次采样间隔超过这个就丢弃（比如断开重连）
    private let maxGap: TimeInterval = 3.0

    private init() {
        load()
    }

    // MARK: - 采样

    /// 每收到一帧控制器数据调用一次
    func update(speedKmh: Double, powerW: Double) {
        let now = Date()
        defer { lastTick = now }

        guard let prev = lastTick else { return }
        let dt = now.timeIntervalSince(prev)
        // 间隔太长（断开过）或者负数，跳过这一帧
        guard dt > 0, dt <= maxGap else { return }

        // 慢速（< 1 km/h）不计里程，避免停车时 GPS 噪声累积
        guard speedKmh >= 1.0 else { return }

        // 里程：速度(km/h) × 时间(h)
        distanceKm += speedKmh * dt / 3600.0
        // 能量：功率(W) × 时间(h) ÷ 1000 = kWh
        // 负功率（回收）也算进去，反映真实净电耗
        energyKWh += powerW * dt / 3600.0 / 1000.0
        movingSeconds += dt

        // 每 10 秒存一次盘，别每帧都写
        saveCounter += 1
        if saveCounter >= 20 {
            saveCounter = 0
            save()
        }
    }

    private var saveCounter = 0

    // MARK: - 清零

    /// 清空所有统计
    func reset() {
        distanceKm = 0
        energyKWh = 0
        movingSeconds = 0
        lastTick = nil
        saveCounter = 0
        save()
    }

    // MARK: - 持久化

    private func save() {
        UserDefaults.standard.set(distanceKm, forKey: keyDistance)
        UserDefaults.standard.set(energyKWh, forKey: keyEnergy)
        UserDefaults.standard.set(movingSeconds, forKey: keySeconds)
    }

    private func load() {
        distanceKm = UserDefaults.standard.double(forKey: keyDistance)
        energyKWh = UserDefaults.standard.double(forKey: keyEnergy)
        movingSeconds = UserDefaults.standard.double(forKey: keySeconds)
    }

    // MARK: - 显示格式化

    /// 里程文字：不足 1km 显示三位小数，否则两位
    var distanceText: String {
        if distanceKm < 1 {
            return String(format: "%.3f", distanceKm)
        }
        return String(format: "%.2f", distanceKm)
    }

    /// 电耗文字
    var consumptionText: String {
        guard hasEnoughData else { return "--" }
        return String(format: "%.1f", consumptionPer100km)
    }

    /// 平均功率文字
    var avgPowerText: String {
        guard movingSeconds > 1 else { return "--" }
        return "\(Int(averagePowerW))"
    }
}
