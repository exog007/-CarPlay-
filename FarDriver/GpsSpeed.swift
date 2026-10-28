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
    /// 静止判定：连续这么久速度都是 0 才算真停下
    private var lastMovingAt: Date = .distantPast

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

    /// 融合车速：控制器轮速和 GPS 取大值
    ///
    /// - Parameters:
    ///   - wheel: 控制器按轮径算出来的速度
    ///   - maxGap: 两者差多少以内算「一致」
    /// - Returns: 用于显示的速度
    func fused(with wheel: Double, maxGap: Double = 15) -> Double {
        guard enabled, hasFix, accuracy >= 0, accuracy < 50 else { return wheel }
        // GPS 比控制器快很多，说明轮径设小了，信 GPS
        if speedKmh > wheel { return speedKmh }
        // GPS 明显比控制器慢，可能刚进隧道/刚起步，控制器的值更及时
        if wheel - speedKmh > maxGap { return wheel }
        return wheel
    }

    /// GPS 是否真的在参与（用于决定要不要在界面标 GPS）
    var isContributing: Bool {
        enabled && hasFix && accuracy >= 0 && accuracy < 50
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

        accuracy = loc.horizontalAccuracy
        hasFix = true

        let kmh = loc.speed * 3.6
        if kmh > 1.0 {
            lastMovingAt = Date()
            speedKmh = kmh
        } else {
            // 停下超过 3 秒才归零，避免 GPS 抖动让数字跳 0
            if Date().timeIntervalSince(lastMovingAt) > 3.0 {
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
