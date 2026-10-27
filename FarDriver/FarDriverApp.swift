//
//  FarDriverApp.swift
//  App 入口
//

import SwiftUI

@main
struct FarDriverApp: App {
    @Environment(\.scenePhase) private var scenePhase

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
