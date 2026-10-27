//
//  FarDriverAttributes.swift
//  Live Activity 的数据结构
//
//  ⚠️ 这个文件必须同时加入【主 App】和【Widget Extension】两个 target
//     因为主 App 要创建/更新 Live Activity，Widget 要渲染它
//

import ActivityKit
import Foundation

struct FarDriverAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        var voltage: Double = 0
        var current: Double = 0
        var power: Double = 0
        var rpm: Double = 0
        var speed: Double = 0
        var gear: Int = 0
        var mosTemp: Int = 0
        var motorTemp: Int = 0
        var soc: Int = 0
        var isRegen: Bool = false

        public init(voltage: Double = 0, current: Double = 0, power: Double = 0,
                    rpm: Double = 0, speed: Double = 0, gear: Int = 0,
                    mosTemp: Int = 0, motorTemp: Int = 0, soc: Int = 0,
                    isRegen: Bool = false) {
            self.voltage = voltage
            self.current = current
            self.power = power
            self.rpm = rpm
            self.speed = speed
            self.gear = gear
            self.mosTemp = mosTemp
            self.motorTemp = motorTemp
            self.soc = soc
            self.isRegen = isRegen
        }
    }

    /// 静态数据：设备名
    var deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }
}
