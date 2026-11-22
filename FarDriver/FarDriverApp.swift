//
//  FarDriverApp.swift
//  App 入口
//

import SwiftUI
import UIKit

@main
struct FarDriverApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 允许代码里主动触发屏幕旋转
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        // ── 按数据源预连接 ──
        //
        // 只启动设置里选中的那一个，避免两个蓝牙设备抢连接。
        if DataSource.isObd {
            // OBD2：ObdManager 在 init 里检测到蓝牙可用后会自动连上次的适配器
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                _ = ObdManager.shared
            }
        } else if BluetoothMemory.autoConnectBms {
            // 远驱模式：预加载 BMS，打开页面直接有数据
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AntBmsManager.shared.startScan()
            }
        }

        // ── 启动直接进竞技仪表 ──
        //
        // 必须在 init 里把风格写进磁盘，不能等 onAppear：
        // ThemeManager.shared 首次访问时会 from load() 读盘，
        // 而 ContentView 的第一帧就依赖这个值。
        // 在这里写好，首帧渲染出来直接就是竞技仪表，不会闪一下标准界面。
        if BluetoothMemory.launchInSportMode {
            var t = AppTheme.load()
            if t.dashStyle != .sport {
                t.dashStyle = .sport
                t.save()
            }
            // 顺便确保是横屏状态
            UserDefaults.standard.set(true, forKey: "forceLandscape")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台时确保在扫描
            if phase == .active {
                if DataSource.isObd {
                    let o = ObdManager.shared
                    if o.status == .disconnected, ObdManager.autoConnect,
                       ObdManager.lastDeviceID != nil {
                        o.reconnect()
                    }
                } else {
                    let m = ControllerManager.shared
                    if m.autoConnect && !m.status.isConnected {
                        m.startScan()
                    }
                }
            }
        }
        .backgroundTask(.appRefresh("com.exog1.fardriver.refresh")) {
            await MainActor.run {
                ControllerManager.shared.uploadIfNeeded()
            }
        }
    }
}
