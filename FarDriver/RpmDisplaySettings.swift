//
//  RpmDisplaySettings.swift
//  转速显示设置 —— 按数据源独立
//
//  为什么单独做一套：
//    AppTheme 里也有 rpmMultiplier，但那是「全局单键」，四个数据源共用一份。
//    电摩的转速原厂报 100（需要 ×10 放大），OBD 报的是真实 800 rpm（×10 就爆表）。
//    所以必须按数据源分开存。
//
//  每个数据源各自记住：
//    · 转速倍率
//    · 转速表满量程
//
//  这几个值不再从 AppTheme 读，避免互相污染。
//

import Foundation
import Combine

/// 转速显示设置（按数据源隔离）
struct RpmDisplay: Codable, Equatable {
    /// 转速倍率：显示的转速 = 原始转速 × 倍率
    var multiplier: Double = 1
    /// 转速表满量程（刻度条跑满对应的转速）
    var scaleMax: Double = 12000

    /// 各数据源的合理默认值
    ///
    ///   远驱：原厂报 100 这种小数值，×10 后显示 1000
    ///   OBD ：报真实转速，倍率 1 即可，满量程按车型给
    static func `default`(for source: DataSource) -> RpmDisplay {
        switch source {
        case .fardriver:
            return RpmDisplay(multiplier: 10, scaleMax: 12000)
        case .motorcycle:
            // 摩托常见红区 10000~14000
            return RpmDisplay(multiplier: 1, scaleMax: 12000)
        case .obd2, .obdYmobd:
            // 汽车常见红区 6000~8000
            return RpmDisplay(multiplier: 1, scaleMax: 8000)
        }
    }
}

/// 转速设置的读写（按数据源隔离）
final class RpmDisplayStore: ObservableObject {

    static let shared = RpmDisplayStore()

    /// 当前数据源的设置（改了就存盘）
    @Published var current: RpmDisplay {
        didSet {
            save(current, for: source)
        }
    }

    /// 当前数据源
    private var source: DataSource = .current

    private init() {
        let s = DataSource.current
        source = s
        current = Self.load(s)
    }

    /// 数据源切了，重新读
    func syncWithDataSource() {
        let s = DataSource.current
        guard s != source else { return }
        source = s
        current = Self.load(s)
    }

    // MARK: - 存储

    private static func key(_ s: DataSource) -> String {
        "rpmDisplay.\(s.storageKey)"
    }

    private static func load(_ s: DataSource) -> RpmDisplay {
        guard let data = UserDefaults.standard.data(forKey: key(s)),
              let v = try? JSONDecoder().decode(RpmDisplay.self, from: data) else {
            return .default(for: s)
        }
        return v
    }

    private func save(_ v: RpmDisplay, for s: DataSource) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(s))
    }

    /// 读指定数据源的设置（设置页遍历用）
    func display(for s: DataSource) -> RpmDisplay {
        Self.load(s)
    }

    /// 写指定数据源的设置
    func setDisplay(_ v: RpmDisplay, for s: DataSource) {
        save(v, for: s)
        if s == source {
            current = v
        }
    }
}
