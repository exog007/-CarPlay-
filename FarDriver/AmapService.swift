//
//  AmapService.swift
//  高德 Web 服务 REST API 封装（搜索 + 驾车路线）
//
//  用的是「Web 服务」类型的 Key，不需要绑 Bundle ID，也不会和免费签名冲突。
//  地图渲染仍然用 Apple MapKit（高德中国区数据就是它提供的），
//  搜索和路线规划走高德，精度更好。
//
//  Key 在「设置 → 高德地图」里填，存在 UserDefaults。
//

import Foundation
import CoreLocation

/// 高德 API Key 存储
enum AmapKey {
    static var value: String {
        get { UserDefaults.standard.string(forKey: "amapKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "amapKey") }
    }

    /// 有没有配 key
    static var configured: Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 高德返回的一个地点
struct AmapPlace: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let distance: Int       // 米

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 距离文字
    var distanceText: String {
        if distance < 1000 { return "\(distance)m" }
        return String(format: "%.1fkm", Double(distance) / 1000.0)
    }
}

/// 高德驾车路线
struct AmapRoute {
    let distance: Int       // 米
    let duration: Int       // 秒
    /// 路径点（经纬度）
    let points: [CLLocationCoordinate2D]

    var distanceText: String {
        if distance < 1000 { return "\(distance)m" }
        return String(format: "%.1fkm", Double(distance) / 1000.0)
    }

    var durationText: String {
        let m = duration / 60
        if m < 60 { return "\(m)分钟" }
        return "\(m / 60)小时\(m % 60)分"
    }
}

enum AmapError: LocalizedError {
    case noKey
    case network(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noKey:            return "还没填高德 Key"
        case .network(let s):   return "网络错误：\(s)"
        case .api(let s):       return s
        }
    }
}

enum AmapService {

    // MARK: - 搜索

    /// 关键字搜索（优先搜当前位置附近，再退回全国）
    static func search(keyword: String,
                       near: CLLocationCoordinate2D?,
                       completion: @escaping (Result<[AmapPlace], Error>) -> Void) {
        guard AmapKey.configured else {
            completion(.failure(AmapError.noKey))
            return
        }
        let key = AmapKey.value.trimmingCharacters(in: .whitespaces)

        var comps = URLComponents(string: "https://restapi.amap.com/v3/place/text")!
        var items = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "keywords", value: keyword),
            URLQueryItem(name: "offset", value: "20"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "extensions", value: "base"),
        ]
        if let c = near {
            // 带上当前位置，结果按距离排序更贴近
            items.append(URLQueryItem(name: "location",
                                      value: String(format: "%.6f,%.6f", c.longitude, c.latitude)))
            items.append(URLQueryItem(name: "sortrule", value: "distance"))
        }
        comps.queryItems = items

        guard let url = comps.url else {
            completion(.failure(AmapError.network("URL 构造失败")))
            return
        }
        get(url) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let json):
                guard let arr = json["pois"] as? [[String: Any]] else {
                    completion(.success([]))
                    return
                }
                let places: [AmapPlace] = arr.compactMap { p in
                    guard let name = p["name"] as? String,
                          let locStr = p["location"] as? String else { return nil }
                    let parts = locStr.split(separator: ",")
                    guard parts.count == 2,
                          let lon = Double(parts[0]),
                          let lat = Double(parts[1]) else { return nil }
                    let addr = (p["address"] as? String) ?? ""
                    let dist = Int((p["distance"] as? String) ?? "0") ?? 0
                    return AmapPlace(name: name,
                                     address: addr.isEmpty ? name : addr,
                                     latitude: lat,
                                     longitude: lon,
                                     distance: dist)
                }
                completion(.success(places))
            }
        }
    }

    // MARK: - 驾车路线

    static func drivingRoute(from: CLLocationCoordinate2D,
                             to: CLLocationCoordinate2D,
                             completion: @escaping (Result<AmapRoute, Error>) -> Void) {
        guard AmapKey.configured else {
            completion(.failure(AmapError.noKey))
            return
        }
        let key = AmapKey.value.trimmingCharacters(in: .whitespaces)

        var comps = URLComponents(string: "https://restapi.amap.com/v3/direction/driving")!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "origin", value: String(format: "%.6f,%.6f", from.longitude, from.latitude)),
            URLQueryItem(name: "destination", value: String(format: "%.6f,%.6f", to.longitude, to.latitude)),
            URLQueryItem(name: "extensions", value: "base"),
            URLQueryItem(name: "strategy", value: "32"),   // 32 = 默认，躲避拥堵优先
        ]

        guard let url = comps.url else {
            completion(.failure(AmapError.network("URL 构造失败")))
            return
        }
        get(url) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let json):
                guard let route = json["route"] as? [String: Any],
                      let paths = route["paths"] as? [[String: Any]],
                      let first = paths.first else {
                    completion(.failure(AmapError.api("高德没返回路线")))
                    return
                }
                let dist = Int((first["distance"] as? String) ?? "0") ?? 0
                let dur = Int((first["duration"] as? String) ?? "0") ?? 0

                // 把所有 step 的 polyline 拼起来
                var coords: [CLLocationCoordinate2D] = []
                if let steps = first["steps"] as? [[String: Any]] {
                    for s in steps {
                        guard let poly = s["polyline"] as? String else { continue }
                        for pair in poly.split(separator: ";") {
                            let xy = pair.split(separator: ",")
                            guard xy.count == 2,
                                  let lon = Double(xy[0]),
                                  let lat = Double(xy[1]) else { continue }
                            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            // 去重，避免相邻重复点
                            if let last = coords.last,
                               abs(last.latitude - c.latitude) < 1e-7,
                               abs(last.longitude - c.longitude) < 1e-7 { continue }
                            coords.append(c)
                        }
                    }
                }
                guard !coords.isEmpty else {
                    completion(.failure(AmapError.api("路线点为空")))
                    return
                }
                completion(.success(AmapRoute(distance: dist, duration: dur, points: coords)))
            }
        }
    }

    // MARK: - 网络

    private static func get(_ url: URL,
                            completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                completion(.failure(AmapError.network(err.localizedDescription)))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(AmapError.network("返回数据解析失败")))
                return
            }
            // 高德用 status "1" 表示成功
            let status = (json["status"] as? String) ?? "0"
            if status != "1" {
                let info = (json["info"] as? String) ?? "未知错误"
                completion(.failure(AmapError.api(info)))
                return
            }
            completion(.success(json))
        }.resume()
    }
}
