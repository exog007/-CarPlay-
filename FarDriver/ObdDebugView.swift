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

    var body: some View {
        NavigationStack {
            List {
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
