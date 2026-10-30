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
import MapKit

/// 高德 API Key 存储
enum AmapKey {

    /// 内置的默认 Key（Web 服务类型）
    ///
    /// 用户可以在设置里覆盖；这里只是免去每次重装都要手动填。
    static let builtIn = "cad1b8a0263e386141633f22140d711b"

    /// 用户在设置里手填的 Key（空表示没填）
    static var custom: String {
        get { UserDefaults.standard.string(forKey: "amapKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "amapKey") }
    }

    /// 实际使用的 Key：优先用用户填的，没有就用内置的
    static var value: String {
        let c = custom.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? builtIn : c
    }

    /// 有没有可用的 key（内置的算有）
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
    /// 分步指令（仿高德导航条）
    let steps: [AmapStep]

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

/// 一条导航指令（高德 step）
struct AmapStep: Identifiable, Equatable {
    let id = UUID()
    /// 导航文字，例如「沿新纬路向北行驶300米后右转」
    let instruction: String
    /// 道路名
    let road: String
    /// 本段距离（米）
    let distance: Int
    /// 本段耗时（秒）
    let duration: Int
    /// 转向动作（高德 action 字段）
    let action: String
    /// 本段起点坐标（用来判断当前在第几段）
    let start: CLLocationCoordinate2D

    /// CLLocationCoordinate2D 不符合 Equatable，这里手动实现
    static func == (lhs: AmapStep, rhs: AmapStep) -> Bool {
        lhs.id == rhs.id
    }

    var distanceText: String {
        if distance < 1000 { return "\(distance)m" }
        return String(format: "%.1fkm", Double(distance) / 1000.0)
    }
}

/// 出行方式
enum TravelMode: String, CaseIterable, Identifiable {
    case car       // 驾车
    case scooter   // 电动车（按骑行算）
    case bicycle   // 自行车
    case walk      // 步行

    var id: String { rawValue }

    var title: String {
        switch self {
        case .car:     return "驾车"
        case .scooter: return "电动车"
        case .bicycle: return "骑行"
        case .walk:    return "步行"
        }
    }

    var icon: String {
        switch self {
        case .car:     return "car.fill"
        case .scooter: return "scooter"
        case .bicycle: return "bicycle"
        case .walk:    return "figure.walk"
        }
    }

    /// 高德 REST 用哪个接口
    /// 电动车走骑行接口（高德没有专门的电动车路径）
    var amapPath: String {
        switch self {
        case .car, .scooter: return "driving"
        case .bicycle, .walk: return "bicycling"
        }
    }

    /// MapKit 对应的交通方式（高德失败时回退）
    var mapKitTransport: MKDirectionsTransportType {
        switch self {
        case .car, .scooter:   return .automobile
        case .bicycle, .walk:  return .walking
        }
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
        route(from: from, to: to, mode: .car, completion: completion)
    }

    /// 统一路线入口：按出行方式走高德对应接口
    static func route(from: CLLocationCoordinate2D,
                      to: CLLocationCoordinate2D,
                      mode: TravelMode,
                      completion: @escaping (Result<AmapRoute, Error>) -> Void) {
        guard AmapKey.configured else {
            completion(.failure(AmapError.noKey))
            return
        }
        let key = AmapKey.value.trimmingCharacters(in: .whitespaces)

        // 骑行走 v4 bicycling，其余走 v3 driving
        let isBike = (mode == .bicycle || mode == .scooter)
        let path = isBike ? "https://restapi.amap.com/v4/direction/bicycling"
                          : "https://restapi.amap.com/v3/direction/driving"

        var comps = URLComponents(string: path)!
        var items = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "origin", value: String(format: "%.6f,%.6f", from.longitude, from.latitude)),
            URLQueryItem(name: "destination", value: String(format: "%.6f,%.6f", to.longitude, to.latitude)),
        ]
        if !isBike {
            items.append(URLQueryItem(name: "extensions", value: "base"))
            items.append(URLQueryItem(name: "strategy", value: "32"))
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
                if let r = parseRoute(json, isBike: isBike) {
                    completion(.success(r))
                } else {
                    completion(.failure(AmapError.api("高德没返回路线")))
                }
            }
        }
    }

    /// 解析高德路线返回（兼容 v3 driving 与 v4 bicycling 两种结构）
    private static func parseRoute(_ json: [String: Any], isBike: Bool) -> AmapRoute? {
        if isBike {
            // v4: { "data": { "paths": [ { distance, duration, steps:[{instruction, road, distance, duration, polyline}] } ] } }
            guard let data = json["data"] as? [String: Any],
                  let paths = data["paths"] as? [[String: Any]],
                  let first = paths.first else { return nil }
            let dist = intValue(first["distance"])
            let dur = intValue(first["duration"])
            let steps = first["steps"] as? [[String: Any]] ?? []
            return buildRoute(distance: dist, duration: dur, steps: steps)
        } else {
            // v3: { "route": { "paths": [...] } }
            guard let route = json["route"] as? [String: Any],
                  let paths = route["paths"] as? [[String: Any]],
                  let first = paths.first else { return nil }
            let dist = intValue(first["distance"])
            let dur = intValue(first["duration"])
            let steps = first["steps"] as? [[String: Any]] ?? []
            return buildRoute(distance: dist, duration: dur, steps: steps)
        }
    }

    private static func buildRoute(distance: Int,
                                   duration: Int,
                                   steps raw: [[String: Any]]) -> AmapRoute? {
        var coords: [CLLocationCoordinate2D] = []
        var steps: [AmapStep] = []

        for s in raw {
            // 道路名
            let road = (s["road"] as? String) ?? ""
            // 指令：v3 有 instruction，v4 可能只有 action
            let action = (s["action"] as? String) ?? ""
            var instr = (s["instruction"] as? String) ?? ""
            if instr.isEmpty {
                instr = action.isEmpty ? road : "\(action) \(road)"
            }
            let d = intValue(s["distance"])
            let du = intValue(s["duration"])

            // 本段起点 = polyline 第一个点
            var firstCoord: CLLocationCoordinate2D?
            if let poly = s["polyline"] as? String {
                for pair in poly.split(separator: ";") {
                    let xy = pair.split(separator: ",")
                    guard xy.count == 2,
                          let lon = Double(xy[0]),
                          let lat = Double(xy[1]) else { continue }
                    let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    if firstCoord == nil { firstCoord = c }
                    if let last = coords.last,
                       abs(last.latitude - c.latitude) < 1e-7,
                       abs(last.longitude - c.longitude) < 1e-7 { continue }
                    coords.append(c)
                }
            }
            if let st = firstCoord {
                steps.append(AmapStep(instruction: instr,
                                      road: road,
                                      distance: d,
                                      duration: du,
                                      action: action,
                                      start: st))
            }
        }
        guard !coords.isEmpty else { return nil }
        return AmapRoute(distance: distance, duration: duration,
                         points: coords, steps: steps)
    }

    private static func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) ?? 0 }
        if let d = v as? Double { return Int(d) }
        return 0
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
