//
//  ObdDebugView.swift
//  OBD2 通信调试面板
//
//  出问题时打开这个页面，能看到：
//    · 适配器名字 / 服务 / 特征 UUID
//    · 初始化握手的每一步有没有回应
//    · 最近发出的指令和收到的原始字符串
//
//  ymobd 能连上说明硬件没问题，出问题多半在协议细节，
//  这个面板就是为了定位到底是哪一步。
//

import SwiftUI

struct ObdDebugView: View {

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject private var obd = ObdManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// 打开时是否自动开始协议探测
    var autoStartProbe: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // ── 一键探测 ──
                Section {
                    Button {
                        obd.autoProbeProtocols()
                    } label: {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(themeMgr.color(.ok))
                            Text(obd.scanningProtocols ? "正在探测…" : "一键自动探测协议")
                                .foregroundStyle(themeMgr.foreground)
                                .font(.subheadline.bold())
                            Spacer()
                            if obd.scanningProtocols {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(obd.scanningProtocols || !obd.status.isConnected)

                    ForEach(Array(obd.probeResults.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.contains("✅") ? themeMgr.color(.ok)
                                             : (line.contains("❌") ? themeMgr.color(.warn)
                                                : themeMgr.foreground))
                    }
                } header: {
                    Text("协议探测")
                } footer: {
                    Text("自动把 9 种 OBD 协议全试一遍。\n找到能通的会自动写入设置，之后重连就能读数据。\n\n整个过程约 1~2 分钟，请耐心等待（车要点火到 ON）。")
                        .font(.caption2)
                }

                // ── 兼容性对照实验 ──
                Section {
                    Button {
                        obd.runCompatTest()
                    } label: {
                        HStack {
                            Image(systemName: "cross.case.fill")
                                .foregroundStyle(themeMgr.color(.warn))
                            Text(obd.compatTesting ? "正在测试…" : "兼容性对照实验")
                                .foregroundStyle(themeMgr.foreground)
                                .font(.subheadline.bold())
                            Spacer()
                            if obd.compatTesting {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(obd.compatTesting || !obd.status.isConnected)

                    ForEach(Array(obd.compatResults.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.contains("✅") ? themeMgr.color(.ok)
                                             : (line.starts(with: "——") ? themeMgr.color(.rpm)
                                                : themeMgr.foreground))
                    }
                } header: {
                    Text("兼容性对照")
                } footer: {
                    Text("协议对了但单 PID 全是 NO DATA 时用这个。\n会用 9 种不同的 AT 配置组合分别去问转速，找出哪一种能拿到真数据。\n\n约 2~3 分钟。")
                        .font(.caption2)
                }

                // ── 连接信息 ──
                Section {
                    row("状态", obd.status.text)
                    row("设备名", obd.deviceName.isEmpty ? "—" : obd.deviceName)
                    row("可写特征", obd.txCharDescription)
                    row("通知特征", obd.notifyCharDescription)
                    row("写入方式", obd.txNeedsResponse ? "withResponse" : "withoutResponse")
                    row("服务数", "\(obd.discoveredServiceCount)")
                } header: {
                    Text("连接信息")
                }

                // ── 握手进度 ──
                Section {
                    ForEach(obd.handshakeLog, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(themeMgr.foreground)
                    }
                    if obd.handshakeLog.isEmpty {
                        Text("还没开始握手")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                    }
                } header: {
                    Text("初始化握手")
                }

                // ── 收发日志 ──
                Section {
                    if obd.txLog.isEmpty {
                        Text("还没有通信记录")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                    }
                    ForEach(Array(obd.txLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(line.hasPrefix(">")
                                             ? themeMgr.color(.rpm)
                                             : themeMgr.foreground)
                            .lineLimit(3)
                    }
                } header: {
                    Text("收发日志（> 发送，< 接收）")
                }

                // ── 支持的 PID ──
                Section {
                    if obd.unsupportedPids.isEmpty {
                        Text("还没检测")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                    } else {
                        Text(obd.unsupportedPids.joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.warn))
                    }
                } header: {
                    Text("不支持的 PID")
                } footer: {
                    Text("这些 PID 这台车不返回数据，轮询时会自动跳过。")
                        .font(.caption2)
                }

                Section {
                    Button {
                        copyAll()
                    } label: {
                        Label(copied ? "已复制" : "复制全部诊断信息",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        obd.clearLogs()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("OBD2 调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
        }
        .onAppear {
            // 从「一键自动探测协议」进来时，立刻开始探测
            if autoStartProbe, obd.status.isConnected {
                obd.autoProbeProtocols()
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundStyle(themeMgr.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(themeMgr.foreground)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func copyAll() {
        var lines: [String] = []
        if !obd.probeResults.isEmpty {
            lines.append("=== 协议探测 ===")
            lines.append(contentsOf: obd.probeResults)
            lines.append("")
        }
        if !obd.compatResults.isEmpty {
            lines.append("=== 兼容性对照 ===")
            lines.append(contentsOf: obd.compatResults)
            lines.append("")
        }
        lines.append("=== 连接信息 ===")
        lines.append("状态: \(obd.status.text)")
        lines.append("设备: \(obd.deviceName)")
        lines.append("可写特征: \(obd.txCharDescription)")
        lines.append("通知特征: \(obd.notifyCharDescription)")
        lines.append("写入方式: \(obd.txNeedsResponse ? "withResponse" : "withoutResponse")")
        lines.append("")
        lines.append("=== 握手 ===")
        lines.append(contentsOf: obd.handshakeLog)
        lines.append("")
        lines.append("=== 不支持 PID ===")
        lines.append(obd.unsupportedPids.joined(separator: ", "))
        lines.append("")
        lines.append("=== 收发日志 ===")
        lines.append(contentsOf: obd.txLog)

        UIPasteboard.general.string = lines.joined(separator: "\n")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
