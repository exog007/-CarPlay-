//
//  WeatherService.swift
//  顶部气温 + 天气小图标
//
//  用系统自带 WeatherKit（iOS 16+）。需要定位权限；拿不到就静默降级，
//  不显示天气块，不影响仪表其他部分。
//

import Foundation
import CoreLocation
import WeatherKit
import Combine

final class WeatherService: NSObject, ObservableObject {

    static let shared = WeatherService()

    /// 当前气温（°C）
    @Published private(set) var temperature: Double?
    /// 天气状况文本（晴 / 多云 / 小雨 …）
    @Published private(set) var conditionText: String = ""
    /// SF Symbol 名字
    @Published private(set) var symbolName: String = "cloud"
    /// 有没有成功拿到过数据
    @Published private(set) var hasData = false
    /// 上次刷新时间
    private var lastFetch: Date?

    private let locationManager = CLLocationManager()
    private var fetching = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// 开始取天气（权限已有才会真的请求）
    func start() {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            requestOnce()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    /// 最多 10 分钟刷新一次，避免频繁请求
    func refreshIfNeeded() {
        if let t = lastFetch, Date().timeIntervalSince(t) < 600 { return }
        requestOnce()
    }

    private func requestOnce() {
        guard !fetching else { return }
        fetching = true
        locationManager.requestLocation()
    }
}

// MARK: - CLLocationManagerDelegate

extension WeatherService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        if st == .authorizedWhenInUse || st == .authorizedAlways {
            requestOnce()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            fetching = false
            return
        }
        Task {
            defer {
                Task { @MainActor in self.fetching = false }
            }
            do {
                let weather = try await WeatherKit.WeatherService.shared
                    .weather(for: loc, including: .current)
                await MainActor.run {
                    self.temperature = weather.temperature.converted(to: .celsius).value
                    self.conditionText = WeatherText.describe(weather.condition)
                    self.symbolName = weather.symbolName
                    self.hasData = true
                    self.lastFetch = Date()
                }
            } catch {
                // 拿不到就保持原样，界面不显示
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fetching = false
    }
}

// MARK: - 天气状况 → 中文

enum WeatherText {
    static func describe(_ condition: WeatherCondition) -> String {
        switch condition {
        case .clear, .mostlyClear, .hot:            return "晴"
        case .partlyCloudy:                           return "多云"
        case .cloudy, .mostlyCloudy:                  return "阴"
        case .foggy, .haze, .smoky:                   return "雾"
        case .drizzle, .freezingDrizzle:              return "毛毛雨"
        case .rain, .freezingRain, .heavyRain:        return "雨"
        case .sunShowers:                             return "阵雨"
        case .thunderstorms, .strongStorms, .isolatedThunderstorms,
             .scatteredThunderstorms:                 return "雷雨"
        case .snow, .flurries, .heavySnow, .blowingSnow,
             .sunFlurries, .wintryMix, .blizzard:     return "雪"
        case .sleet:                                  return "雨夹雪"
        case .hail:                                   return "冰雹"
        case .breezy, .windy:                         return "大风"
        case .tropicalStorm, .hurricane:              return "风暴"
        default:                                      return "—"
        }
    }
}
