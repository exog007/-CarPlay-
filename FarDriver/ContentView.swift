//
//  ContentView.swift
//  主界面：仪表盘 + 连接控制 + 上传设置
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var mgr = ControllerManager.shared
    @StateObject private var bms = AntBmsManager.shared
    @StateObject private var themeMgr = ThemeManager.shared
    @StateObject private var gps = GpsSpeed.shared
    @State private var showSettings = false
    @State private var showBms = false
    @State private var landscapeRequested = false

    /// 最终显示的车速：控制器轮速和 GPS 融合
    private var displaySpeed: Double {
        gps.fused(with: mgr.data.speed)
    }

    /// 是不是 P 档
    ///
    /// 直接读控制器上报的 P 档状态（0xE2 的 p[0] bit0），
    /// 不再靠速度/电流推断。删掉原来的 1.5 秒静止计时逻辑。
    private var isParked: Bool {
        guard mgr.status.isConnected, mgr.data.e2Seen else { return false }
        return mgr.data.pGearOn
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let sportMode = (themeMgr.theme.dashStyle == .sport)
            NavigationStack {
                Group {
                    if landscape && sportMode {
                        // 竞技风格：整屏黑底，不要导航栏和卡片，铺满
                        ScrollView {
                            SportDashView(mgr: mgr, themeMgr: themeMgr, gps: gps)
                                .frame(minHeight: geo.size.height - 60)
                        }
                        .scrollContentBackground(.hidden)
                        .background(Color(hex: themeMgr.theme.sportBgHex).ignoresSafeArea())
                    } else {
                        ScrollView {
                            VStack(spacing: 12) {
                                statusCard
                                if landscape {
                                    // 横屏标准：左速度 / 中档位 / 右电压功率
                                    landscapePanel
                                } else {
                                    gearRow
                                    mainGauges
                                    tempRow
                                    batteryRow
                                }
                            }
                            .padding()
                            .animation(.easeInOut(duration: 0.2), value: landscape)
                        }
                        .scrollContentBackground(.hidden)
                        .background(themeMgr.backgroundView)
                    }
                }
                .navigationTitle(landscape && sportMode ? "" : "大肥鱼控制器")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            rotateScreen(currentLandscape: landscape)
                        } label: {
                            Image(systemName: landscape
                                  ? "rectangle.portrait.rotate"
                                  : "rectangle.landscape.rotate")
                        }
                    }
                    // 竞技/标准切换：横屏时一键换皮肤
                    if landscape {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    themeMgr.theme.dashStyle =
                                        sportMode ? .standard : .sport
                                }
                            } label: {
                                Image(systemName: sportMode
                                      ? "rectangle.split.3x1.fill"
                                      : "speedometer")
                                    .foregroundStyle(sportMode
                                                     ? themeMgr.color(.power)
                                                     : themeMgr.foreground)
                            }
                        }
                    }
                    // 蚂蚁 BMS
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showBms = true
                        } label: {
                            Image(systemName: "battery.100percent.bolt")
                                .foregroundStyle(bms.connected ? themeMgr.color(.ok) : themeMgr.foreground)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(mgr: mgr)
                }
                .fullScreenCover(isPresented: $showBms) {
                    AntBmsView(bms: bms, themeMgr: themeMgr)
                }
            }
            .preferredColorScheme(themeMgr.isLight ? .light : .dark)
            .onAppear {
                // 记下用户上次选的横屏状态
                landscapeRequested = UserDefaults.standard.bool(forKey: "forceLandscape")
                if landscapeRequested {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        applyOrientation(true)
                    }
                }
                // 启动 GPS 车速（会弹一次定位授权）
                gps.start()
                // 打开 App 就不自动息屏，方便骑行时一直看仪表
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                // 离开主界面时恢复系统自动息屏，别把电耗光
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: - 横竖屏切换

    private func rotateScreen(currentLandscape: Bool) {
        let target = !currentLandscape
        landscapeRequested = target
        UserDefaults.standard.set(target, forKey: "forceLandscape")
        applyOrientation(target)
    }

    private func applyOrientation(_ landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }

        // iOS 16+ 的正式接口：直接请求屏幕几何方向
        if #available(iOS 16.0, *) {
            let prefs = UIWindowScene.GeometryPreferences.iOS(
                interfaceOrientations: landscape ? .landscapeRight : .portrait
            )
            scene.requestGeometryUpdate(prefs) { error in
                // 旋转失败（比如被别的东西锁住）就把开关状态退回去
                print("旋转失败：\(error.localizedDescription)")
            }
            // 让 SwiftUI 重新算布局
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        } else {
            UIDevice.current.setValue(
                landscape ? UIInterfaceOrientation.landscapeRight.rawValue
                          : UIInterfaceOrientation.portrait.rawValue,
                forKey: "orientation"
            )
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(mgr.status.isConnected ? themeMgr.color(.ok) : Color.gray)
                    .frame(width: 10, height: 10)
                Text(mgr.status.text)
                    .font(.subheadline)
                    .foregroundStyle(themeMgr.foreground)
                Spacer()
                Button {
                    if mgr.status.isConnected {
                        mgr.disconnect()
                    } else if mgr.status == .scanning {
                        mgr.stopScan()
                    } else {
                        mgr.startScan()
                    }
                } label: {
                    Text(mgr.status.isConnected ? "断开" : (mgr.status == .scanning ? "停止" : "搜索蓝牙"))
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(mgr.status.isConnected
                                    ? themeMgr.color(.warn).opacity(0.2)
                                    : themeMgr.color(.rpm))
                        .foregroundStyle(mgr.status.isConnected ? themeMgr.color(.warn) : Color.white)
                        .clipShape(Capsule())
                }
            }

            // 搜索到的设备列表：已连接后自动收起
            if !mgr.status.isConnected && !mgr.discovered.isEmpty {
                Divider().background(themeMgr.secondary.opacity(0.3))
                Text("搜索到 \(mgr.discovered.count) 个设备，点一下连接：")
                    .font(.caption)
                    .foregroundStyle(themeMgr.secondary)
                ForEach(mgr.discovered, id: \.id) { dev in
                    Button {
                        mgr.connect(to: dev.id)
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundStyle(themeMgr.color(.rpm))
                            Text(dev.name)
                                .font(.subheadline)
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text("\(dev.rssi) dBm")
                                .font(.caption2)
                                .foregroundStyle(themeMgr.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(themeMgr.isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            // 错误信息
            if let e = mgr.uploadError {
                Text(e)
                    .font(.caption2)
                    .foregroundStyle(themeMgr.color(.power))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 蓝牙记忆诊断：告诉你记忆了什么、开关开没开
            if !mgr.status.isConnected {
                if let lastName = BluetoothMemory.lastControllerName, !lastName.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: BluetoothMemory.autoConnectController
                              ? "pin.circle.fill" : "pin.slash")
                            .font(.caption2)
                            .foregroundStyle(BluetoothMemory.autoConnectController
                                             ? themeMgr.color(.ok) : themeMgr.secondary)
                        Text(BluetoothMemory.autoConnectController
                             ? "记忆：\(lastName)（搜到自动连）"
                             : "记忆：\(lastName)（自动连已关）")
                            .font(.caption2)
                            .foregroundStyle(themeMgr.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("还没记住控制器，连一次就会记住")
                        .font(.caption2)
                        .foregroundStyle(themeMgr.secondary)
                }
            }

            // GPS 速度表状态：没授权时提示一下，不然用户以为功能没做
            if gps.enabled && !gps.authorized {
                HStack(spacing: 6) {
                    Image(systemName: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(themeMgr.color(.warn))
                    Text("GPS 车速需要定位权限，点这里去设置")
                        .font(.caption2)
                        .foregroundStyle(themeMgr.color(.warn))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }

            // 定位授权了就自动开定位，不用用户再点
            if gps.enabled && gps.authorized && !gps.hasFix {
                Text("GPS 正在搜星…（室外几秒后出速度）")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
            }
        }
        .padding()
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    // MARK: - 横屏主面板

    /// 横屏布局：左边速度表 / 中间很窄的 P + 123 档 / 右边电压和实时功率
    private var landscapePanel: some View {
        HStack(alignment: .top, spacing: 12) {
            speedometerLarge
                .frame(maxWidth: .infinity)

            gearColumn
                .frame(width: 78)

            VStack(spacing: 12) {
                StatCard(
                    title: "电压",
                    value: String(format: "%.1f", mgr.data.voltage),
                    unit: "V",
                    color: themeMgr.color(.voltage),
                    theme: themeMgr
                )
                StatCard(
                    title: "实时功率",
                    value: powerText,
                    unit: "W",
                    color: mgr.data.isRegen ? themeMgr.color(.ok) : themeMgr.color(.power),
                    theme: themeMgr
                )
                tempRow
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 功率文字：回收时带负号
    private var powerText: String {
        let p = Int(mgr.data.power)
        return mgr.data.power < -1 ? "−\(abs(p))" : "\(p)"
    }

    /// 大号速度表（GPS + 轮速融合）
    private var speedometerLarge: some View {
        let kmh = displaySpeed
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("速度")
                    .font(.system(size: 12))
                    .foregroundStyle(themeMgr.secondary)
                if gps.isContributing {
                    Image(systemName: "location.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(themeMgr.color(.ok))
                }
            }
            Spacer(minLength: 0)
            Text("\(Int(kmh.rounded()))")
                .font(.system(size: 82, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(themeMgr.foreground)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text("km/h")
                .font(.system(size: 13))
                .foregroundStyle(themeMgr.secondary)
            Spacer(minLength: 0)
            // 速度条，一眼看出快慢
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(themeMgr.isLight
                              ? Color.black.opacity(0.08)
                              : Color.white.opacity(0.12))
                    Capsule()
                        .fill(themeMgr.color(.ok))
                        .frame(width: max(0, min(1, kmh / 100)) * g.size.width)
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.15), value: kmh)
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    /// 中间窄列：P 档 + 1/2/3 档
    private var gearColumn: some View {
        // P 档信号还没在协议里找到，先按「车速 0 且没电流」判定
        let parked = mgr.status.isConnected
                     && abs(mgr.data.current) < 0.5
                     && displaySpeed < 1.0
        let gear = mgr.data.gear
        return VStack(spacing: 8) {
            Text(parked ? "P" : " ")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(parked ? themeMgr.color(.warn) : Color.clear)
                )

            ForEach([3, 2, 1], id: \.self) { g in
                let on = (gear == g) && !parked
                Text("\(g)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(on ? Color.black : themeMgr.foreground.opacity(gear == 0 ? 0.18 : 0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(on ? themeMgr.color(.rpm)
                                     : (themeMgr.isLight ? Color.black.opacity(0.06)
                                                         : Color.white.opacity(0.10)))
                    )
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    // MARK: - 档位

    /// 档位条：1/2/3 三格，亮到当前档位
    ///
    /// 遥控器本身是几档就只显示几档。gearbox 为 0 表示还没收到数据，
    /// 这时整条压暗，不和「1 档」混淆。
    private var gearRow: some View {
        let gear = mgr.data.gear
        let hasData = gear >= 1
        return HStack(spacing: 8) {
            Image(systemName: "gearshift.layout.sixspeed")
                .font(.system(size: 14))
                .foregroundStyle(themeMgr.secondary)

            Text("档位")
                .font(.system(size: 11))
                .foregroundStyle(themeMgr.secondary)

            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { g in
                    Text("\(g)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(g == gear
                                         ? Color.black
                                         : themeMgr.foreground.opacity(hasData ? 0.45 : 0.18))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(g == gear
                                      ? themeMgr.color(.rpm)
                                      : (themeMgr.isLight ? Color.black.opacity(0.06)
                                                          : Color.white.opacity(0.10)))
                        )
                }
            }

            Spacer(minLength: 0)

            // 右边放回收提示，省一行
            if mgr.data.isRegen {
                Text("回收")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(themeMgr.color(.ok))
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    // MARK: - 主仪表（转速 + 功率）

    private var mainGauges: some View {
        HStack(spacing: 12) {
            GaugeCard(
                title: "电机转速",
                value: "\(Int(mgr.data.rpm))",
                unit: "rpm",
                color: themeMgr.color(.rpm),
                progress: min(mgr.data.rpm / 8000, 1),
                theme: themeMgr
            )
            GaugeCard(
                title: "实时功率",
                value: "\(Int(mgr.data.power))",
                unit: "W",
                color: themeMgr.color(.power),
                progress: min(mgr.data.power / 5000, 1),
                theme: themeMgr
            )
        }
    }

    // MARK: - 温度

    private var tempRow: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "MOS 温度",
                value: "\(mgr.data.mosTemp)",
                unit: "°C",
                color: mgr.data.mosTemp > 60 ? themeMgr.color(.warn) : themeMgr.color(.mosTemp),
                warn: mgr.data.mosTemp > 60,
                showTriangleWarning: mgr.data.mosTemp > 60,
                theme: themeMgr
            )
            StatCard(
                title: "电机温度",
                value: "\(mgr.data.motorTemp)",
                unit: "°C",
                color: mgr.data.motorTemp > 50 ? themeMgr.color(.warn) : themeMgr.color(.motorTemp),
                warn: mgr.data.motorTemp > 50,
                showEngineWarning: mgr.data.motorTemp > 50,
                theme: themeMgr
            )
        }
    }

    // MARK: - 电池

    private var batteryRow: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "电压",
                value: String(format: "%.1f", mgr.data.voltage),
                unit: "V",
                color: themeMgr.color(.voltage),
                theme: themeMgr
            )
            StatCard(
                title: "电流",
                value: String(format: "%.1f", mgr.data.current),
                unit: "A",
                color: mgr.data.isRegen ? themeMgr.color(.ok) : themeMgr.color(.current),
                theme: themeMgr
            )
        }
    }

}

// MARK: - 仪表卡

struct GaugeCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color
    let progress: Double
    var theme: ThemeManager?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme?.secondary ?? .secondary)
            ZStack {
                Circle()
                    .stroke(theme?.isLight == true
                            ? Color.black.opacity(0.08)
                            : Color.white.opacity(0.12),
                            lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
                VStack(spacing: 2) {
                    Text(value)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme?.foreground ?? .white)
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(theme?.secondary ?? .secondary)
                }
            }
            .frame(height: 130)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(theme?.cardBG ?? Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme?.cardStroke ?? Color.clear, lineWidth: 1)
        }
    }
}

// MARK: - 数据卡

struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color
    var warn: Bool = false
    /// MOS 温度超限：红三角 + 白色感叹号
    var showTriangleWarning: Bool = false
    /// 电机温度超限：黄色水温/发动机故障灯
    var showEngineWarning: Bool = false
    var theme: ThemeManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(theme?.secondary ?? .secondary)
                if showTriangleWarning {
                    TriangleWarningIcon()
                }
                if showEngineWarning {
                    EngineWarningIcon()
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(warn ? (theme?.color(.warn) ?? .red) : color)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(theme?.secondary ?? .secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warn
                    ? (theme?.color(.warn) ?? .red).opacity(0.12)
                    : (theme?.cardBG ?? Color(white: 0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if warn {
                RoundedRectangle(cornerRadius: 14)
                    .stroke((theme?.color(.warn) ?? .red).opacity(0.5), lineWidth: 1)
            }
        }
    }
}




// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var showAppearance = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showAppearance = true
                    } label: {
                        HStack {
                            Image(systemName: "paintpalette.fill")
                                .foregroundStyle(themeMgr.color(.rpm))
                            Text("外观（背景 / 颜色）")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(themeMgr.isLight ? "浅色" : "深色")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("个性化")
                }

                Section {
                    TextField("服务器地址", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("本地 deepseek 地址")
                } footer: {
                    Text("例如 http://192.168.100.101:38281\n手机和电脑要在同一个 WiFi 下")
                }

                Section {
                    Toggle("自动连接控制器", isOn: $mgr.autoConnect)
                } header: {
                    Text("蓝牙")
                } footer: {
                    Text("关闭后不会自动搜索控制器，需要手动点「搜索蓝牙」")
                }

                Section {
                    Toggle("记住控制器，搜到就自动连",
                           isOn: Binding(
                            get: { BluetoothMemory.autoConnectController },
                            set: { BluetoothMemory.autoConnectController = $0 }
                           ))
                    if let n = BluetoothMemory.lastControllerName, !n.isEmpty {
                        HStack {
                            Text("上次连接")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(n)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("记住 BMS，搜到就自动连",
                           isOn: Binding(
                            get: { BluetoothMemory.autoConnectBms },
                            set: { BluetoothMemory.autoConnectBms = $0 }
                           ))
                    if let n = BluetoothMemory.lastBmsName, !n.isEmpty {
                        HStack {
                            Text("上次连接的 BMS")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(n)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("蓝牙记忆")
                } footer: {
                    Text("打开后，App 会记住上次连过的设备。下次进入 App 搜索时，一旦发现那台设备就自动连接，不用手动点。")
                }

                Section {
                    Toggle("自动上传（每 60 秒）", isOn: $mgr.autoUpload)
                } header: {
                    Text("数据上传")
                } footer: {
                    Text("主界面的上传卡片上也有这个开关，两边同步")
                }

                Section {
                    HStack {
                        Text("小计里程")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text("\(TripMeter.shared.distanceText) km")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("累计电量")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text(String(format: "%.3f kWh", TripMeter.shared.energyKWh))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("百公里电耗")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text("\(TripMeter.shared.consumptionText) kWh")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.ok))
                    }
                    HStack {
                        Text("平均功率")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text("\(TripMeter.shared.avgPowerText) W")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        TripMeter.shared.reset()
                    } label: {
                        Label("清空小计里程", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("行程统计")
                } footer: {
                    Text("里程按控制器速度 × 时间累加；百公里电耗 = 累计电量 ÷ 里程 × 100。清空后重新统计。")
                }

                Section {
                    Button("测试连接服务器") {
                        testServer()
                    }
                }

                Section("说明") {
                    Label("MOS 温度超过 60°C 亮红三角警告", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Label("电机温度超过 50°C 亮黄色发动机故障灯", systemImage: "engine.combustion.fill")
                        .font(.caption)
                    Label("电流为负表示在动能回收", systemImage: "arrow.down.circle")
                        .font(.caption)
                    Label("左上角按钮切换横屏/竖屏", systemImage: "rectangle.landscape.rotate")
                        .font(.caption)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        mgr.serverBaseURL = url.trimmingCharacters(in: .whitespaces)
                        dismiss()
                    }
                }
            }
            .onAppear { url = mgr.serverBaseURL }
            .sheet(isPresented: $showAppearance) {
                AppearanceView(themeMgr: themeMgr)
            }
        }
    }

    private func testServer() {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces) + "/health") else { return }
        let manager = mgr
        URLSession.shared.dataTask(with: u) { _, resp, _ in
            DispatchQueue.main.async {
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    manager.setUploadError(nil)
                    UIAlertController(title: "连接成功", message: "服务器正常", preferredStyle: .alert)
                        .presentingShow()
                } else {
                    manager.setUploadError("连不上服务器")
                }
            }
        }.resume()
    }
}

extension UIAlertController {
    func presentingShow() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(self, animated: true)
    }
}

#Preview {
    ContentView()
}
