//
//  ContentView.swift
//  主界面：仪表盘 + 连接控制 + 上传设置
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var mgr = ControllerManager.shared
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    mainGauges
                    tempRow
                    batteryRow
                    uploadCard
                }
                .padding()
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("远驱控制器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(mgr.status.isConnected ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(mgr.status.text)
                    .font(.subheadline)
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
                        .background(mgr.status.isConnected ? Color.red.opacity(0.2) : Color.blue)
                        .foregroundStyle(mgr.status.isConnected ? Color.red : Color.white)
                        .clipShape(Capsule())
                }
            }

            // 搜索到的设备列表：已连接后自动收起
            if !mgr.status.isConnected && !mgr.discovered.isEmpty {
                Divider().background(Color.gray.opacity(0.3))
                Text("搜索到 \(mgr.discovered.count) 个设备，点一下连接：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(mgr.discovered, id: \.id) { dev in
                    Button {
                        mgr.connect(to: dev.id)
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundStyle(.cyan)
                            Text(dev.name)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(dev.rssi) dBm")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color(white: 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            // 错误信息
            if let e = mgr.uploadError {
                Text(e)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 主仪表（转速 + 功率）

    private var mainGauges: some View {
        HStack(spacing: 12) {
            GaugeCard(
                title: "电机转速",
                value: "\(Int(mgr.data.rpm))",
                unit: "rpm",
                color: .cyan,
                progress: min(mgr.data.rpm / 8000, 1)
            )
            GaugeCard(
                title: "实时功率",
                value: "\(Int(mgr.data.power))",
                unit: "W",
                color: .orange,
                progress: min(mgr.data.power / 5000, 1)
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
                color: mgr.data.mosTemp > 75 ? .red : .orange,
                warn: mgr.data.mosTemp > 75
            )
            StatCard(
                title: "电机温度",
                value: "\(mgr.data.motorTemp)",
                unit: "°C",
                color: mgr.data.motorTemp > 110 ? .red : .pink,
                warn: mgr.data.motorTemp > 110
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
                color: .yellow
            )
            StatCard(
                title: "电流",
                value: String(format: "%.1f", mgr.data.current),
                unit: "A",
                color: mgr.data.isRegen ? .green : .mint
            )
        }
        .overlay(alignment: .topTrailing) {
            if mgr.data.isRegen {
                Text("回收")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                    .padding(8)
            }
        }
    }

    // MARK: - 上传状态

    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text("数据上传")
                    .font(.subheadline.bold())
                Spacer()
                Text(mgr.autoUpload ? "每 60 秒" : "已关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("档位")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(mgr.data.gear)")
                    .font(.title3.bold())
                    .foregroundStyle(.cyan)
                Spacer()
                if mgr.data.isRegen {
                    Text("能量回收中")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let t = mgr.lastUpload {
                Text("上次上传：\(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if let e = mgr.uploadError {
                Text("上传失败：\(e)")
                    .font(.caption2)
                    .foregroundStyle(.red)
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
                .background(mgr.liveActivityRunning ? Color.red.opacity(0.85) : Color.green.opacity(0.85))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!mgr.status.isConnected)

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
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!mgr.status.isConnected)
        }
        .padding()
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 仪表卡

struct GaugeCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color
    let progress: Double

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .stroke(Color(white: 0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
                VStack(spacing: 2) {
                    Text(value)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 130)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 数据卡

struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color
    var warn: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(warn ? Color.red : color)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warn ? Color.red.opacity(0.12) : Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if warn {
                RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var mgr: ControllerManager
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
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
                    Toggle("自动上传（每 60 秒）", isOn: $mgr.autoUpload)
                    Toggle("自动连接控制器", isOn: $mgr.autoConnect)
                }

                Section {
                    Button("测试连接服务器") {
                        testServer()
                    }
                }

                Section("说明") {
                    Label("MOS 温度超过 75°C 会变红", systemImage: "thermometer.high")
                        .font(.caption)
                    Label("电机温度超过 110°C 会变红", systemImage: "thermometer.high")
                        .font(.caption)
                    Label("电流为负表示在动能回收", systemImage: "arrow.down.circle")
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
