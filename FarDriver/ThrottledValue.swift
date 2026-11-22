//
//  ThrottledValue.swift
//  降频发射工具
//
//  设置页里有几个数值来自高频数据源（GPS 60Hz、控制器每秒多次），
//  但设置页只需要「偶尔看一眼当前值」，没必要跟着 60Hz 重绘。
//  这里提供一个 2Hz 的节流包装，只在这些值上使用。
//

import Foundation
import Combine

/// 把高频的数值降频成 2Hz 再发布
final class ThrottledValue: ObservableObject {

    /// 当前值（2Hz 更新）
    @Published private(set) var value: Double = 0

    private var lastEmit: Date = .distantPast
    private let interval: TimeInterval
    /// 上次真正发出去的值，变化太小就不发
    private var lastValue: Double = .nan

    init(interval: TimeInterval = 0.5) {
        self.interval = interval
    }

    /// 外部喂新值，内部决定要不要真的发布
    func push(_ v: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= interval else { return }
        // 变化小于 0.05 就不折腾 UI
        if !lastValue.isNaN, abs(v - lastValue) < 0.05 { return }
        lastEmit = now
        lastValue = v
        value = v
    }

    /// 强制立即发一次（例如刚进入设置页）
    func force(_ v: Double) {
        lastEmit = Date()
        lastValue = v
        value = v
    }
}

/// 把任意符合 ObservableObject 的对象的某个 Double 字段，降频成 2Hz
///
/// 用法：在设置页里
///   @StateObject private var speedThrottle = ThrottledValue()
///   ...
///   .onReceive(mgr.$data) { d in speedThrottle.push(d.rawSpeed) }
struct ThrottleGate: ViewModifier {

    let source: AnyPublisher<Double, Never>
    @ObservedObject var throttle: ThrottledValue

    func body(content: Content) -> some View {
        content.onReceive(source) { throttle.push($0) }
    }
}

extension View {
    /// 把一个高频数值源接到节流器上（只做副作用，不改变视图）
    func throttleInto(_ throttle: ThrottledValue,
                      from source: AnyPublisher<Double, Never>) -> some View {
        onReceive(source) { throttle.push($0) }
    }
}
