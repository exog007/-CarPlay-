//
//  FeatureFlags.swift
//  功能开关
//
//  这里集中管理「还没验证过 / 暂时隐藏」的功能，
//  改一个常量就能开/关，不用去翻视图代码。
//

import Foundation

enum SelfLearnSwitch {
    /// 是否显示「电机自学习」入口
    ///
    /// 目前是 false。原因：
    ///   自学习指令的字节格式未经验证。
    ///   官方 App 是 Xamarin AOT 编译的，组包逻辑在编译后的机器码里，
    ///   无法从 MotorNet6.dll 还原出来（那个 dll 里只有参数名和文案）。
    ///
    /// 恢复条件（两个都满足才能改成 true）：
    ///   1. 抓到了官方 App 做自学习时的 BLE 写入日志（nRF Connect 之类）
    ///   2. 对着日志把 FarDriverCommand.swift 里的字节改对
    ///
    /// 代码本身是完整的（SelfLearnView.swift / FarDriverCommand.swift），
    /// 只是入口被这个开关挡住了。
    static let visible = false
}
