//
//  ObdValueStore.swift
//  通用 PID 数据仓库
//
//  ymobd 能读到 91 个 PID，这里全部接收并存起来，
//  界面上暂时不用的也留着，方便后续调用。
//

import Foundation
import Combine

/// 一条 PID 的当前值
struct ObdValue {
    let code: String
    let name: String
    let unit: String
    let value: Double
    let updatedAt: Date
    /// 格式化后的显示文本（带单位）
    var text: String {
        let v = unit == "%" || unit == "rpm" || unit == "km/h"
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
        return unit.isEmpty ? v : "\(v) \(unit)"
    }
}

final class ObdValueStore: ObservableObject {

    static let shared = ObdValueStore()

    /// 所有已收到的数据，key = code（如 "010C"）
    @Published private(set) var values: [String: ObdValue] = [:]

    private init() {}

    func update(code: String, value: Double) {
        guard let def = ObdPidTable.def(code) else { return }
        let v = ObdValue(code: code,
                         name: def.name,
                         unit: def.unit,
                         value: value,
                         updatedAt: Date())
        // 只在值有明显变化时才发布，避免高频刷新拖慢 UI
        if let old = values[code], abs(old.value - value) < 0.01 {
            return
        }
        values[code] = v
    }

    func get(_ code: String) -> Double? {
        values[code]?.value
    }

    func clear() {
        values.removeAll()
    }

    /// 按名称排序的所有值（调试面板展示用）
    var sortedList: [ObdValue] {
        values.values.sorted { $0.code < $1.code }
    }
}
