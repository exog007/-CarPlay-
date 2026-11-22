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

    /// 当前 GPS 原始速度 km/h（每 1 秒跳一次）
    @Published private(set) var speedKmh: Double = 0
    /// 平滑后的显示速度（每 50ms 追一次，看起来连续）
    @Published private(set) var smoothSpeed: Double = 0
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
    /// 60Hz 平滑定时器：每帧朝目标速度靠一点，把 1 秒一次的数字跳变变成连续变化
    private var smoothTimer: Timer?
    /// 平滑系数：每帧追 18%，约 0.25 秒追到 90%
    private let smoothFactor: Double = 0.18
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
        startSmoothTimer()
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
        smoothSpeed = 0
        hasFix = false
        smoothTimer?.invalidate()
        smoothTimer = nil
    }

    /// 临时挂起平滑定时器（进入设置页时调用）
    ///
    /// 设置页不需要 60Hz 的实时速度，但它是 @ObservedObject 的，
    /// 不停的话整页 Form 每秒被重绘 60 次，看起来就掉帧。
    /// 停掉只影响平滑动画，仪表本身的数值来源不受影响。
    func pauseSmoothing() {
        smoothTimer?.invalidate()
        smoothTimer = nil
    }

    /// 恢复平滑（离开设置页时调用）
    func resumeSmoothing() {
        guard enabled, manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else { return }
        startSmoothTimer()
    }

    /// 上次真正发布出去的平滑值（用来跳过无意义的重绘）
    private var lastPublishedSmooth: Double = -1

    /// 启动平滑定时器：每 16ms 让 smoothSpeed 朝 speedKmh 追一步
    ///
    /// ⚠️ 性能：这个定时器每秒跑 60 次，如果每次都写 @Published，
    /// 所有观察 gps 的视图（包括设置页）都会每秒重绘 60 次，明显掉帧。
    /// 这里做了两级过滤：
    ///   · 已经追平（差值 < 0.05）→ 不再赋值
    ///   · 变化量 < 0.01 → 不提交
    private func startSmoothTimer() {
        guard smoothTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let target = self.speedKmh
            let cur = self.smoothSpeed
            let diff = target - cur
            let next = abs(diff) < 0.05 ? target : cur + diff * self.smoothFactor

            // 已经追平且发布过同样的值 → 直接跳过
            if abs(diff) < 0.05, abs(self.lastPublishedSmooth - next) < 0.001 {
                return
            }
            // 变化太小，肉眼看不出来，不折腾 SwiftUI
            if abs(next - self.lastPublishedSmooth) < 0.01 { return }

            self.lastPublishedSmooth = next
            self.smoothSpeed = next
        }
        // 给点容差，系统可以合并唤醒，省电也省 CPU
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        smoothTimer = t
    }

    // MARK: - 读数

    /// 显示车速
    ///
    /// 按用户要求：**只用控制器转速换算**（原始值 × 微调系数）。
    /// GPS 不再参与显示速度，只用于地图定位和「一键校准」参考。
    ///
    /// - Parameter wheel: 控制器转速换算出的时速（已含微调系数）
    /// - Returns: 用于显示的速度
    func fused(with wheel: Double) -> Double {
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
