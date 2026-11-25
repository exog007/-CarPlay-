//
//  RedlineConfig.swift
//  转速顶满爆闪的配置
//
//  可在「设置 → 个性化 → 外观 → 转速显示」里调：
//    · 是否启用
//    · 触发阈值（满量程的百分之几开始闪）
//    · 闪烁速度（每秒闪几下）
//    · 闪烁强度（颜色变化幅度）
//
//  全局一份（不分数据源），因为它描述的是「报警手势」而不是某个车型的特性。
//

import Foundation
import Combine

struct RedlineConfig: Codable, Equatable {
    /// 是否启用爆闪
    var enabled: Bool = true
    /// 触发阈值：0.90 = 满量程 90% 开始闪
    var threshold: Double = 0.97
    /// 闪烁周期（秒）：越小闪得越快
    ///
    ///   0.08 → 约 6Hz（很快，很刺眼）
    ///   0.16 → 约 3Hz（默认，醒目）
    ///   0.40 → 约 1.2Hz（慢速呼吸）
    var period: Double = 0.16
    /// 强度：0.3 = 轻微，1.0 = 全白热
    var intensity: Double = 1.0

    /// 默认配置
    static let `default` = RedlineConfig()

    /// 阈值百分比文字（如 "97%"）
    var thresholdText: String {
        String(format: "%.0f%%", threshold * 100)
    }

    /// 闪烁频率文字（如 "6.3 Hz"）
    var hzText: String {
        guard period > 0 else { return "--" }
        return String(format: "%.1f Hz", 1.0 / period)
    }

    // MARK: - 存取

    private static let key = "redlineConfig"

    static func load() -> RedlineConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(RedlineConfig.self, from: data) else {
            return .default
        }
        return v
    }

    static func save(_ v: RedlineConfig) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 全局访问点（改了立刻持久化）
final class RedlineStore: ObservableObject {
    static let shared = RedlineStore()

    @Published var config: RedlineConfig {
        didSet { RedlineConfig.save(config) }
    }

    private init() {
        config = RedlineConfig.load()
    }
}
