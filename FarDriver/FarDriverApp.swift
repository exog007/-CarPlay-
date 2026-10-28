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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台时确保在扫描/上传
            if phase == .active {
                let m = ControllerManager.shared
                if m.autoConnect && !m.status.isConnected {
                    m.startScan()
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
