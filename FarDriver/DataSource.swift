//
//  DataSource.swift
//  数据源选择：远驱控制器 / OBD2 汽车摩托
//
//  两者互斥：选哪个就只启动哪个，不会同时抢占蓝牙。
//

import Foundation
import Combine

enum DataSource: String, CaseIterable, Identifiable {
    case fardriver = "fardriver"
    case obd2      = "obd2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fardriver: return "远驱控制器（电动车/电摩）"
        case .obd2:      return "OBD2（汽车/摩托车）"
        }
    }

    var shortTitle: String {
        switch self {
        case .fardriver: return "远驱"
        case .obd2:      return "OBD2"
        }
    }

    var subtitle: String {
        switch self {
        case .fardriver: return "通过远驱 BLE 控制器读取电压/电流/转速/温度"
        case .obd2:      return "通过 ELM327 适配器读取转速/车速/水温/电瓶电压/故障码"
        }
    }

    var icon: String {
        switch self {
        case .fardriver: return "bolt.car.fill"
        case .obd2:      return "car.fill"
        }
    }

    /// 读当前选择
    static var current: DataSource {
        get {
            let raw = UserDefaults.standard.string(forKey: "dataSource") ?? ""
            return DataSource(rawValue: raw) ?? .fardriver
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "dataSource")
        }
    }

    /// 是不是 OBD2 模式（仪表据此隐藏电机/BMS 区块）
    static var isObd: Bool { current == .obd2 }
}
