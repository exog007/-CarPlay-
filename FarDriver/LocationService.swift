//
//  LocationService.swift
//  给动态仪表的地图用：持续获取当前位置
//

import Foundation
import CoreLocation
import Combine

final class LocationService: NSObject, ObservableObject {

    static let shared = LocationService()

    /// 当前位置
    @Published private(set) var location: CLLocation?
    /// 有没有定位授权
    @Published private(set) var authorized = false
    /// 朝向（度，0 = 正北）
    @Published private(set) var heading: Double = 0

    private let manager = CLLocationManager()
    private var started = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    func start() {
        guard !started else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            authorized = true
            started = true
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            authorized = false
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        started = false
    }
}

extension LocationService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        let ok = (st == .authorizedWhenInUse || st == .authorizedAlways)
        authorized = ok
        if ok { start() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        location = loc
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // trueHeading 为负表示无效，退回磁北
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        heading = h
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 静默忽略，地图会停在最后一次位置
    }
}
