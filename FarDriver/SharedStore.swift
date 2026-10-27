//
//  SharedStore.swift
//  App Group 共享存储（主 App 和 CarPlay 小组件共用）
//
//  注意：ControllerData 定义在 FarDriverProtocol.swift，这里不重复定义
//  两个 target 都要包含这个文件
//

import Foundation

enum SharedStore {
    static let suiteName = "group.com.exog1.fardriver"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// 存最新一份控制器数据（主 App 调用）
    static func save(_ d: ControllerData) {
        let dict: [String: Any] = [
            "voltage": d.voltage,
            "current": d.current,
            "power": d.power,
            "rpm": d.rpm,
            "speed": d.speed,
            "gear": d.gear,
            "mosTemp": d.mosTemp,
            "motorTemp": d.motorTemp,
            "soc": d.soc,
            "regen": d.isRegen,
            "updatedAt": d.updatedAt.timeIntervalSince1970,
        ]
        defaults.set(dict, forKey: "latestControllerData")
    }

    /// 读最新数据（小组件调用）
    static func load() -> ControllerData? {
        guard let dict = defaults.dictionary(forKey: "latestControllerData") else { return nil }
        var d = ControllerData.empty
        d.voltage = dict["voltage"] as? Double ?? 0
        d.current = dict["current"] as? Double ?? 0
        d.power = dict["power"] as? Double ?? 0
        d.rpm = dict["rpm"] as? Double ?? 0
        d.speed = dict["speed"] as? Double ?? 0
        d.gear = dict["gear"] as? Int ?? 0
        d.mosTemp = dict["mosTemp"] as? Int ?? 0
        d.motorTemp = dict["motorTemp"] as? Int ?? 0
        d.soc = dict["soc"] as? Int ?? 0
        d.isRegen = dict["regen"] as? Bool ?? false
        if let t = dict["updatedAt"] as? Double {
            d.updatedAt = Date(timeIntervalSince1970: t)
        }
        return d
    }

    static func saveServerURL(_ url: String) { defaults.set(url, forKey: "serverURL") }

    static func loadServerURL() -> String {
        defaults.string(forKey: "serverURL") ?? "http://192.168.100.101:38281"
    }
}
