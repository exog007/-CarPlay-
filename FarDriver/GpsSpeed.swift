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
    /// 平滑系数（从设置里读，切换档位立即生效）
    private var smoothFactor: Double { GpsRefreshRate.current.smoothFactor }
    /// 最后一次 GPS 读到「在动」的时间
    private var lastMovingAt: Date = .distantPast
    /// 最后一次收到定位回调的时间（用来判断 GPS 是否还在喂数据）
    private var lastLocationAt: Date = .distantPast

    override init() {
        super.init()
        manager.delegate = self
        // 最高精度 + 不限距离：每次系统给点就用，不做节流
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        // iOS 10+：允许系统在两次定位之间做插值，
        // 把 1Hz 的原始定位补到约 10Hz，速度变化更跟手。
        if #available(iOS 10.0, *) {
            manager.pausesLocationUpdatesAutomatically = false
        }
        // 允许后台更新（App 在后台时也能持续喂速度）
        manager.allowsBackgroundLocationUpdates = true
        // 让系统知道这是「高功率」导航场景，给它 1Hz 甚至更高的点
        manager.showsBackgroundLocationIndicator = false
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
            startLocationKick()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            authorized = false
        }
    }

    /// 强制刷新定位回调用
    ///
    /// iOS 的 startUpdatingLocation 有时会降频（检测到静止或近似位置）。
    /// 每隔 0.5 秒补一次 requestLocation()，能让系统早点把新点送上来。
    /// 只在有授权时跑，App 进后台后系统会自动节流。
    private var kickTimer: Timer?

    private func startLocationKick() {
        guard kickTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let st = self.manager.authorizationStatus
            guard st == .authorizedWhenInUse || st == .authorizedAlways else { return }
            // 只在最近 2 秒没收到新点时补一次，避免打断正常的连续更新
            if Date().timeIntervalSince(self.lastLocationAt) > 1.5 {
                self.manager.requestLocation()
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        kickTimer = t
    }

    func stop() {
        manager.stopUpdatingLocation()
        kickTimer?.invalidate()
        kickTimer = nil
        lastPoint = nil
        speedTrend = 0
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

    /// 刷新率档位改了，重建平滑定时器
    ///
    /// 定时器的频率在创建时就固定了，改档位必须重建才生效。
    func applyRefreshRate() {
        smoothTimer?.invalidate()
        smoothTimer = nil
        guard enabled else { return }
        let st = manager.authorizationStatus
        guard st == .authorizedWhenInUse || st == .authorizedAlways else { return }
        startSmoothTimer()
    }

    /// 恢复平滑（离开设置页时调用）
    func resumeSmoothing() {
        guard enabled, manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else { return }
        startSmoothTimer()
    }

    /// 上次真正发布出去的平滑值（用来跳过无意义的重绘）
    private var lastPublishedSmooth: Double = -1

    /// 上一次收到的 GPS 速度点（速度 + 时间）
    private var lastPoint: (speed: Double, time: Date)?
    /// 速度变化率（km/h 每秒），用来在两点之间做线性预测
    private var speedTrend: Double = 0

    /// 启动平滑定时器：每 16ms 让 smoothSpeed 朝 speedKmh 追一步
    ///
    /// ⚠️ 性能：这个定时器每秒跑 60 次，如果每次都写 @Published，
    /// 所有观察 gps 的视图（包括设置页）都会每秒重绘 60 次，明显掉帧。
    /// 这里做了两级过滤：
    ///   · 已经追平（差值 < 0.05）→ 不再赋值
    ///   · 变化量 < 0.01 → 不提交
    private func startSmoothTimer() {
        guard smoothTimer == nil else { return }
        let rate = GpsRefreshRate.current
        let t = Timer(timeInterval: 1.0 / rate.timerHz, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // ── 预测插值 ──
            //
            // GPS 每秒只给 1~2 个点，两点之间原本是「等」，看起来就卡。
            // 这里用上一次算出的速度变化率（speedTrend）外推：
            //   预测速度 = 上个点 + 变化率 × 已经过去的秒数
            //
            // 距离上个点越远，外推越多，但最多外推 1.5 秒（再多就不可信了）。
            let base = self.speedKmh
            var target = base
            if let lp = self.lastPoint {
                let elapsed = Date().timeIntervalSince(lp.time)
                if elapsed > 0, elapsed < 1.5, abs(self.speedTrend) > 0.1 {
                    let predicted = lp.speed + self.speedTrend * elapsed
                    // 预测值不偏离实际值太远，避免飞出去
                    target = max(min(predicted, base + 8), base - 8)
                    target = max(0, target)
                }
            }

            let cur = self.smoothSpeed
            let diff = target - cur
            let next = abs(diff) < 0.02 ? target : cur + diff * self.smoothFactor

            // 已经追平且发布过同样的值 → 直接跳过
            if abs(diff) < 0.02, abs(self.lastPublishedSmooth - next) < 0.001 {
                return
            }
            // 变化太小就不提交（阈值随档位变）
            if abs(next - self.lastPublishedSmooth) < rate.publishThreshold { return }

            self.lastPublishedSmooth = next
            self.smoothSpeed = next
        }
        // 容差随档位变：省电档允许合并唤醒，极速档必须准时
        t.tolerance = rate.tolerance
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
        // 精度太差的不要，但阈值放宽到 50 米：
        // 车在跑时 GPS 水平精度会变差，可速度值本身仍然准
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }

        accuracy = loc.horizontalAccuracy
        hasFix = true
        lastLocationAt = Date()

        let kmh = loc.speed * 3.6
        let now = Date()

        // 计算速度变化率，供插值预测用
        if let lp = lastPoint {
            let dt = now.timeIntervalSince(lp.time)
            // 只在不正常跳变范围内用（>3 秒或 >30 km/h 的变化当作噪声丢弃）
            if dt > 0.1, dt < 3.0, abs(kmh - lp.speed) < 30 {
                let raw = (kmh - lp.speed) / dt
                // 平滑一下趋势，避免单次噪声放大
                speedTrend = speedTrend * 0.4 + raw * 0.6
                // 限制趋势范围，防止插值飞出去
                speedTrend = max(-25, min(25, speedTrend))
            } else {
                speedTrend = 0
            }
        }
        lastPoint = (kmh, now)

        // 低于 2 km/h 一律当静止（GPS 静止噪声约 1~3 km/h，取 2 兼顾灵敏和稳定）
        if kmh > 2.0 {
            lastMovingAt = now
            speedKmh = kmh
        } else {
            // 停下超过 2 秒才归零，避免正常抖动让数字跳 0
            if now.timeIntervalSince(lastMovingAt) > 2.0 {
                speedKmh = 0
                speedTrend = 0
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失败就退回控制器车速，不影响仪表
        hasFix = false
        speedKmh = 0
    }
}
