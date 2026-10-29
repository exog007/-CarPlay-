//
//  WeatherService.swift
//  顶部气温 + 天气小图标
//
//  数据源分两级，按顺序试：
//    ① WeatherKit（系统自带，最准，但免费签名账号可能没权限）
//    ② wttr.in（免费公开接口，不要 key，免费签名也能用）
//
//  WeatherKit 拿不到就自动退回 wttr.in，所以只要手机能上网就能显示天气。
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
    /// 数据来自哪个源（调试用）
    @Published private(set) var sourceName: String = ""

    /// 上次刷新时间
    private var lastFetch: Date?
    /// 上次拿到的坐标，避免每次都重新定位
    private var cachedCoordinate: CLLocationCoordinate2D?

    private let locationManager = CLLocationManager()
    private var fetching = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - 入口

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

    /// 最多 10 分钟刷新一次
    func refreshIfNeeded() {
        if let t = lastFetch, Date().timeIntervalSince(t) < 600 { return }
        requestOnce()
    }

    private func requestOnce() {
        guard !fetching else { return }
        // 有缓存坐标就直接拉数据，不用再定位
        if let c = cachedCoordinate {
            fetchWeather(at: c)
            return
        }
        fetching = true
        locationManager.requestLocation()
    }

    // MARK: - 拉数据

    private func fetchWeather(at coord: CLLocationCoordinate2D) {
        guard !fetching else { return }
        fetching = true
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        Task {
            // ① 先试 WeatherKit
            if await tryWeatherKit(at: loc) {
                await MainActor.run {
                    self.fetching = false
                    self.lastFetch = Date()
                }
                return
            }
            // ② 不行就退到 wttr.in
            let ok = await tryWttrIn(at: coord)
            await MainActor.run {
                self.fetching = false
                if ok { self.lastFetch = Date() }
            }
        }
    }

    /// WeatherKit 取一次，成功返回 true
    private func tryWeatherKit(at loc: CLLocation) async -> Bool {
        do {
            let w = try await WeatherKit.WeatherService.shared
                .weather(for: loc, including: .current)
            await MainActor.run {
                self.temperature = w.temperature.converted(to: .celsius).value
                self.conditionText = WeatherText.describe(w.condition)
                self.symbolName = w.symbolName
                self.hasData = true
                self.sourceName = "WeatherKit"
            }
            return true
        } catch {
            return false
        }
    }

    /// wttr.in 取一次，成功返回 true
    private func tryWttrIn(at coord: CLLocationCoordinate2D) async -> Bool {
        let lat = String(format: "%.4f", coord.latitude)
        let lon = String(format: "%.4f", coord.longitude)
        guard let url = URL(string: "https://wttr.in/\(lat),\(lon)?format=j1") else {
            return false
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        // wttr.in 用纯文本返回更省流量
        req.setValue("curl/8", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = (json["current_condition"] as? [[String: Any]])?.first else {
                return false
            }

            let tempStr = cur["temp_C"] as? String ?? ""
            let code = Int(cur["weatherCode"] as? String ?? "0") ?? 0
            let desc = ((cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)

            guard let temp = Double(tempStr) else { return false }

            await MainActor.run {
                self.temperature = temp
                self.conditionText = WeatherText.describe(wttrCode: code, fallback: desc)
                self.symbolName = WeatherText.symbol(wttrCode: code)
                self.hasData = true
                self.sourceName = "wttr.in"
            }
            return true
        } catch {
            return false
        }
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
        let coord = loc.coordinate
        cachedCoordinate = coord
        fetching = false
        fetchWeather(at: coord)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fetching = false
    }
}

// MARK: - 天气状况 → 中文 / 图标

enum WeatherText {

    // MARK: WeatherKit

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

    // MARK: wttr.in 天气码

    /// WorldWeatherOnline 天气码 → 中文
    static func describe(wttrCode code: Int, fallback: String) -> String {
        switch code {
        case 113:                       return "晴"
        case 116:                       return "多云"
        case 119, 122:                  return "阴"
        case 143, 248, 260:             return "雾"
        case 176, 263, 266, 293, 296:   return "小雨"
        case 299, 302, 305, 308:        return "雨"
        case 353, 356, 359:             return "阵雨"
        case 200, 386, 389:             return "雷雨"
        case 311, 314, 317, 320, 350:   return "雨夹雪"
        case 179, 182, 185, 281, 284,
             323, 326, 329, 332, 335, 338: return "雪"
        case 368, 371, 374, 377:        return "雪"
        case 227, 230, 395, 398:        return "暴雪"
        case 392:                       return "冰雹"
        default:
            // 认不出来就退回英文描述（或空）
            return fallback.isEmpty ? "—" : fallback
        }
    }

    /// wttr.in 天气码 → SF Symbol
    static func symbol(wttrCode code: Int) -> String {
        switch code {
        case 113:                               return "sun.max.fill"
        case 116:                               return "cloud.sun.fill"
        case 119, 122:                          return "cloud.fill"
        case 143, 248, 260:                     return "cloud.fog.fill"
        case 176, 263, 266, 293, 296:           return "cloud.drizzle.fill"
        case 299, 302, 305, 308:                return "cloud.rain.fill"
        case 353, 356, 359:                     return "cloud.heavyrain.fill"
        case 200, 386, 389:                     return "cloud.bolt.rain.fill"
        case 179, 182, 227, 230, 323, 326, 329,
             332, 335, 338, 368, 371, 395, 398: return "cloud.snow.fill"
        case 311, 314, 317, 320, 350, 374, 377: return "cloud.sleet.fill"
        default:                                return "cloud.fill"
        }
    }
}
