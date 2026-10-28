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
    @State private var showSettings = false
    @State private var showParams = false
    @State private var showBms = false
    @State private var landscapeRequested = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        if landscape {
                            // 横屏：左右两栏，仪表和数据并排，一屏看全
                            HStack(alignment: .top, spacing: 16) {
                                VStack(spacing: 16) {
                                    mainGauges
                                    batteryRow
                                }
                                .frame(maxWidth: .infinity)
                                VStack(spacing: 16) {
                                    tempRow
                                    faultRow
                                    uploadCard
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            // 竖屏：原来的单列
                            mainGauges
                            tempRow
                            batteryRow
                            faultRow
                            uploadCard
                        }
                    }
                    .padding()
                    .animation(.easeInOut(duration: 0.2), value: landscape)
                }
                .scrollContentBackground(.hidden)
                .background(themeMgr.backgroundView)
                .navigationTitle("大肥鱼控制器")
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
                    // 二级菜单：控制器参数
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showParams = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
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
                .sheet(isPresented: $showParams) {
                    ParamView(mgr: mgr, themeMgr: themeMgr)
                }
                .sheet(isPresented: $showBms) {
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
        }
        .padding()
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
        .overlay(alignment: .topTrailing) {
            if mgr.data.isRegen {
                Text("回收")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(themeMgr.color(.ok))
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                    .padding(8)
            }
        }
    }

    // MARK: - 故障码

    private var faultRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: mgr.data.hasFault ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(mgr.data.hasFault ? themeMgr.color(.warn) : themeMgr.color(.ok))

                Text("故障码")
                    .font(.caption)
                    .foregroundStyle(themeMgr.secondary)

                if mgr.data.hasFault {
                    Text(mgr.data.faultText)
                        .font(.caption.bold())
                        .foregroundStyle(themeMgr.color(.warn))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(mgr.data.faultFrameSeen ? "系统正常" : "没收到故障帧")
                        .font(.caption.bold())
                        .foregroundStyle(mgr.data.faultFrameSeen ? themeMgr.color(.ok) : themeMgr.secondary)
                }

                Spacer(minLength: 0)

                if mgr.data.faultFrameSeen {
                    Text("0x\(String(format: "%04X", mgr.data.faultCode))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(themeMgr.secondary)
                }
            }

            // 调试行：原始字节（方便和官方 App 对照）
            if mgr.data.faultFrameSeen && !mgr.data.faultRaw.isEmpty {
                Text(mgr.data.faultRaw)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(mgr.data.hasFault ? themeMgr.color(.warn).opacity(0.12) : themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if mgr.data.hasFault {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(themeMgr.color(.warn).opacity(0.5), lineWidth: 1)
            }
        }
    }

    // MARK: - 上传状态

    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 第一行：标题 + 开关（开关方式上传）
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(mgr.autoUpload ? themeMgr.color(.ok) : Color.gray)
                Text("数据上传")
                    .font(.subheadline.bold())
                    .foregroundStyle(themeMgr.foreground)
                Spacer()
                Toggle("", isOn: $mgr.autoUpload)
                    .labelsHidden()
                    .tint(themeMgr.color(.ok))
            }

            Text(mgr.autoUpload ? "正在上传：每 60 秒自动传一次" : "已停止上传（打开开关开始传）")
                .font(.caption)
                .foregroundStyle(mgr.autoUpload ? themeMgr.color(.ok).opacity(0.9) : themeMgr.secondary)

            // 档位
            HStack(spacing: 12) {
                Text("档位")
                    .font(.caption)
                    .foregroundStyle(themeMgr.secondary)
                Text("\(mgr.data.gear)")
                    .font(.title3.bold())
                    .foregroundStyle(themeMgr.color(.rpm))
                Spacer()
                if mgr.data.isRegen {
                    Text("能量回收中")
                        .font(.caption)
                        .foregroundStyle(themeMgr.color(.ok))
                }
            }

            if let t = mgr.lastUpload {
                Text("上次上传：\(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.color(.ok))
            }
            if let e = mgr.uploadError {
                Text("上传失败：\(e)")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.color(.warn))
            }

            // CarPlay / 锁屏实时活动
            Button {
                if mgr.liveActivityRunning {
                    mgr.stopLiveActivity()
                } else {
                    mgr.startLiveActivity()
                }
            } label: {
                HStack {
                    Image(systemName: mgr.liveActivityRunning ? "stop.circle.fill" : "car.fill")
                    Text(mgr.liveActivityRunning ? "停止 CarPlay 显示" : "在 CarPlay 显示")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(mgr.liveActivityRunning
                            ? themeMgr.color(.warn).opacity(0.85)
                            : themeMgr.color(.ok).opacity(0.85))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!mgr.status.isConnected)

            // 手动补传一次：开关关掉也能点
            Button {
                mgr.upload()
            } label: {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                    Text("立刻上传一次")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(themeMgr.color(.current))
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!mgr.status.isConnected)
        }
        .padding()
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(mgr.autoUpload ? themeMgr.color(.ok).opacity(0.35) : themeMgr.cardStroke,
                        lineWidth: 1)
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
                    Toggle("自动上传（每 60 秒）", isOn: $mgr.autoUpload)
                } header: {
                    Text("数据上传")
                } footer: {
                    Text("主界面的上传卡片上也有这个开关，两边同步")
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
