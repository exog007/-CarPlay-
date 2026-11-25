//
//  RpmSmoother.swift
//  转速平滑器
//
//  为什么单独做一个 ObservableObject：
//    smoothRpm 之前放在 SportDashView 的 @State 里，
//    每帧变化都会让整个仪表 body 重绘。body 里有几十个视图，
//    60Hz 下 SwiftUI 来不及布局，表现为转速条「一顿一顿」。
//
//    拆成独立对象后，只有真正读 value 的视图（数字、转速条）会刷新，
//    其它区块（档位、油表、底部六格……）完全不动。
//

import Foundation
import Combine

final class RpmSmoother: ObservableObject {

    /// 当前平滑后的转速
    @Published private(set) var value: Double = 0

    /// 平滑定时器（外部启动/停止）
    var timer: Timer?

    /// 追赶系数（每帧走剩余差值的比例）
    ///
    ///   0.28 → 60Hz 下约 0.12 秒追到 90%
    ///   大跳变时用 0.45，反应更快
    /// 30Hz 下每帧追多一点，等效响应速度和 60Hz@0.28 一致
    private let factorSmall: Double = 0.45
    private let factorBig: Double = 0.62
    /// 多大的跳变算「大」
    private let bigJump: Double = 3000

    /// 直接设值（自检结束等场景用，避免从满量程滑下来）
    func snap(to v: Double) {
        guard abs(v - value) > 0.01 else { return }
        value = v
    }

    /// 推进一帧
    ///
    /// - Parameter target: 目标转速
    func tick(target: Double) {
        let cur = value
        let diff = target - cur

        // 追上就吸附（只在真不同时写，避免无意义重绘）
        if abs(diff) < 1 {
            if cur != target { value = target }
            return
        }

        let f = abs(diff) > bigJump ? factorBig : factorSmall
        let next = cur + diff * f

        // 变化太小时不刷（肉眼看不出来，省重绘）
        if abs(next - cur) > 0.5 {
            value = next
        }
    }
}
