//
//  ObdSniffView.swift
//  蓝牙抓包页（逆向私有协议用）
//
//  用途：连上 MTB / JBT 这类非 ELM327 模块，记录它发出的原始字节，
//  分析帧结构（帧头、长度、校验、命令字）。
//

import SwiftUI

struct ObdSniffView: View {

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject private var obd = ObdManager.shared
    @Environment(\.dismiss) private var dismiss

    /// 手动发一条 hex（试探协议）
    @State private var sendHex = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    // ── 状态 ──
                    HStack(spacing: 8) {
                        Circle()
                            .fill(obd.status.isConnected ? themeMgr.color(.ok) : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(obd.status.isConnected
                             ? "已连接 \(obd.deviceName)"
                             : obd.status.text)
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                        Spacer()
                        Text("\(obd.sniffByteCount) B / \(obd.sniffLog.count) 帧")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.rpm))
                    }
                    .padding(.horizontal, 4)

                    // ── 操作 ──
                    HStack(spacing: 10) {
                        Button {
                            obd.clearSniff()
                        } label: {
                            Label("清空", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(themeMgr.color(.warn))

                        Button {
                            UIPasteboard.general.string = obd.sniffDump()
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "已复制" : "复制全部", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(themeMgr.color(.ok))
                        .disabled(obd.sniffLog.isEmpty)

                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    // ── 手动发 hex ──
                    HStack(spacing: 8) {
                        TextField("手动发送 hex，如 01 0C", text: $sendHex)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                        Button("发送") {
                            obd.sniffSend(hex: sendHex)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeMgr.color(.power))
                        .disabled(!obd.status.isConnected || sendHex.isEmpty)
                    }
                    .padding(.horizontal, 4)

                    Divider()

                    // ── 帧列表 ──
                    if obd.sniffLog.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 32))
                                .foregroundStyle(themeMgr.secondary.opacity(0.5))
                            Text(obd.status.isConnected ? "还没有收到数据" : "还没连接模块")
                                .font(.subheadline)
                                .foregroundStyle(themeMgr.secondary)
                            Text("连上模块后，等它自己发数据（或者用手动发送试探）")
                                .font(.caption2)
                                .foregroundStyle(themeMgr.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(obd.sniffLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix(">>>")
                                                     ? themeMgr.color(.warn)
                                                     : themeMgr.color(.ok))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
            .navigationTitle("蓝牙抓包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }
}
