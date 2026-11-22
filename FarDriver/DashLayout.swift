//
//  DashLayout.swift
//  竞技仪表的布局微调参数
//
//  拆成两个方向独立缩放 + 两个方向的整体位移：
//    · scaleX  横向缩放
//    · scaleY  纵向缩放
//    · shiftX  整体左右挪（正数往右）
//    · shiftY  整体上下挪（正数往下）
//
//  这样「左边切掉一点」「底部顶出去」这种问题都能单独修。
//

import Foundation
import SwiftUI

struct DashLayout: Codable, Equatable {

    /// 横向缩放 0.70 ~ 1.30
    var scaleX: Double = 1.0
    /// 纵向缩放 0.70 ~ 1.30
    var scaleY: Double = 1.0
    /// 水平位移 -60 ~ +60（pt，按参考画布坐标）
    var shiftX: Double = 0
    /// 垂直位移 -60 ~ +60
    var shiftY: Double = 0

    static let reset = DashLayout()

    /// 夹到安全范围
    var safeScaleX: CGFloat { CGFloat(min(max(scaleX, 0.70), 1.30)) }
    var safeScaleY: CGFloat { CGFloat(min(max(scaleY, 0.70), 1.30)) }
    var safeShiftX: CGFloat { CGFloat(min(max(shiftX, -60), 60)) }
    var safeShiftY: CGFloat { CGFloat(min(max(shiftY, -60), 60)) }
}

/// 存取（全局一份，两个数据源共用布局参数）
///
/// 布局参数和主题分开放：换颜色/背景不该重置尺寸。
///
/// ⚠️ 性能：拖滑块时每秒会产生几十次改动，
/// 每次都 JSON 编码 + 写 UserDefaults 会明显卡顿。
/// 所以拆成两步：
///   ① 内存里立刻更新 + 通知界面重绘（实时反馈）
///   ② 停手 250ms 后才真正写盘（防抖）
final class DashLayoutStore: ObservableObject {

    static let shared = DashLayoutStore()

    @Published private(set) var revision: Int = 0

    /// 内存中的当前值（界面读这个，改完立刻生效）
    @Published private(set) var current: DashLayout

    private let key = "dashLayout"
    private var saveWork: DispatchWorkItem?

    private init() {
        if let d = UserDefaults.standard.data(forKey: "dashLayout"),
           let l = try? JSONDecoder().decode(DashLayout.self, from: d) {
            current = l
        } else {
            current = .reset
        }
    }

    var layout: DashLayout {
        get { current }
        set {
            current = newValue
            revision += 1
            scheduleSave()
        }
    }

    /// 延迟写盘：250ms 内的多次改动合并成一次
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = current
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let d = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(d, forKey: self.key)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// 只改缩放
    func setScale(x: Double, y: Double) {
        var l = current
        l.scaleX = min(max(x, 0.70), 1.30)
        l.scaleY = min(max(y, 0.70), 1.30)
        layout = l
    }

    /// 只改位移
    func setShift(x: Double, y: Double) {
        var l = current
        l.shiftX = min(max(x, -60), 60)
        l.shiftY = min(max(y, -60), 60)
        layout = l
    }

    func reset() {
        layout = .reset
        // 重置要立刻落盘，避免用户马上退出 App 丢失
        saveWork?.cancel()
        if let d = try? JSONEncoder().encode(DashLayout.reset) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}
