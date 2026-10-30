//
//  GpsSpeed.swift
//  GPS 速度表
//
//  用手机 GPS 拿实时速度（km/h），和控制器算出来的轮速互相印证。
//  默认取「更快」的那个：GPS 在低速时会跳 0，控制器在轮径不对时会偏低，
//  取大值比取小值更接近真实车速，不会让仪表在骑行中突然掉到 0。
//

import Foundation
import CoreLocation
import Combine

final class GpsSpeed: NSObject, ObservableObject {

    static let shared = GpsSpeed()

    /// 当前 GPS 速度 km/h
    @Published private(set) var speedKmh: Double = 0
    /// 有没有定位授权
    @Published private(set) var authorized: Bool = false
    /// 定位精度（米），越小越可信
    @Published private(set) var accuracy: Double = -1
    /// 有没有拿到过有效速度
    @Published private(set) var hasFix: Bool = false
    /// 是否启用（用户开关）
    @Published var enabled: Bool = true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "gpsSpeedEnabled")
            if enabled { start() } else { stop() }
        }
    }

    private let manager = CLLocationManager()
    /// 最后一次 GPS 读到「在动」的时间
    private var lastMovingAt: Date = .distantPast
    /// 最后一次收到定位回调的时间（用来判断 GPS 是否还在喂数据）
    private var lastLocationAt: Date = .distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        enabled = UserDefaults.standard.object(forKey: "gpsSpeedEnabled") as? Bool ?? true
    }

    // MARK: - 控制

    func start() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            authorized = true
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            authorized = false
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        speedKmh = 0
        hasFix = false
    }

    // MARK: - 读数

    /// 融合车速：GPS 为主，控制器兜底
    ///
    /// 方案 C：
    ///   ① 有 GPS 信号且精度够 → 用 GPS（真实对地速度，不受轮径/极对数误差影响）
    ///   ② GPS 没信号（隧道/车库）→ 用控制器转速换算
    ///   ③ GPS 读到 0 但控制器有速度（刚起步/低速 GPS 不出数）→ 用控制器
    ///
    /// - Parameter wheel: 控制器按轮径算出来的速度
    /// - Returns: 用于显示的速度
    func fused(with wheel: Double) -> Double {
        // 没开 GPS / 没定位 / 精度太差 → 全用控制器
        guard enabled, hasFix, accuracy >= 0, accuracy < 30 else { return wheel }

        // GPS 有速度，直接用它
        if speedKmh >= 1.0 { return speedKmh }

        // GPS 是 0，但车在动（刚起步 GPS 还没出数），用控制器
        return wheel
    }

    /// GPS 是否真的在参与（用于决定要不要在界面标 GPS）
    var isContributing: Bool {
        enabled && hasFix && accuracy >= 0 && accuracy < 30
    }
}

// MARK: - CLLocationManagerDelegate

extension GpsSpeed: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        let ok = (st == .authorizedWhenInUse || st == .authorizedAlways)
        authorized = ok
        if ok && enabled {
            manager.startUpdatingLocation()
        } else {
            stop()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // 负速度表示无效
        guard loc.speed >= 0 else { return }
        // 太旧的定位不要
        guard abs(loc.timestamp.timeIntervalSinceNow) < 5 else { return }
        // 精度太差的定位不要：>30 米时速度基本是噪声，静止也会读出 3~10 km/h
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 30 else { return }

        accuracy = loc.horizontalAccuracy
        hasFix = true
        lastLocationAt = Date()

        let kmh = loc.speed * 3.6
        // 低于 3 km/h 一律当静止：GPS 在静止时的速度噪声通常就是这个量级
        if kmh > 3.0 {
            lastMovingAt = Date()
            speedKmh = kmh
        } else {
            // 停下超过 2 秒才归零，避免正常抖动让数字跳 0
            if Date().timeIntervalSince(lastMovingAt) > 2.0 {
                speedKmh = 0
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失败就退回控制器车速，不影响仪表
        hasFix = false
        speedKmh = 0
    }
}
