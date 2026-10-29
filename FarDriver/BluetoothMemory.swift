//
//  BluetoothMemory.swift
//  蓝牙记忆：记住上次连过的设备，再搜到时自动连
//

import Foundation

/// 保存/读取上次连接的设备 UUID
enum BluetoothMemory {

    /// 控制器上次连的设备
    static var lastControllerID: String? {
        get { UserDefaults.standard.string(forKey: "lastControllerID") }
        set { UserDefaults.standard.set(newValue, forKey: "lastControllerID") }
    }

    /// ANT BMS 上次连的设备
    static var lastBmsID: String? {
        get { UserDefaults.standard.string(forKey: "lastBmsID") }
        set { UserDefaults.standard.set(newValue, forKey: "lastBmsID") }
    }

    /// 上次连的设备名（显示用）
    static var lastControllerName: String? {
        get { UserDefaults.standard.string(forKey: "lastControllerName") }
        set { UserDefaults.standard.set(newValue, forKey: "lastControllerName") }
    }

    static var lastBmsName: String? {
        get { UserDefaults.standard.string(forKey: "lastBmsName") }
        set { UserDefaults.standard.set(newValue, forKey: "lastBmsName") }
    }

    /// 自动连接开关（控制器）
    static var autoConnectController: Bool {
        get {
            if UserDefaults.standard.object(forKey: "autoConnectController") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "autoConnectController")
        }
        set { UserDefaults.standard.set(newValue, forKey: "autoConnectController") }
    }

    /// 自动连接开关（BMS）
    static var autoConnectBms: Bool {
        get {
            if UserDefaults.standard.object(forKey: "autoConnectBms") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "autoConnectBms")
        }
        set { UserDefaults.standard.set(newValue, forKey: "autoConnectBms") }
    }
}
