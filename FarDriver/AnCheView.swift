//
//  AnCheView.swift
//  AnChe（金奔腾）协议测试页
//
//  在已连接的 BLE 链路上收发 AnChe 帧，验证协议是否可用。
//

import SwiftUI

struct AnCheView: View {

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject private var obd = ObdManager.shared
    @ObservedObject private var anche = AnCheManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var manualHex = ""
    @State private var copied = false
    @State private var selectedCode: AnCheCode? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    statusBar
                    quickActions
                    streamSection
                    logSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
            .navigationTitle("AnChe 协议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    // MARK: - 状态

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(obd.status.isConnected ? themeMgr.color(.ok) : Color.gray)
                    .frame(width: 9, height: 9)
                Text(obd.status.isConnected ? "BLE 已连接" : obd.status.text)
                    .font(.caption.bold())
                    .foregroundStyle(themeMgr.foreground)
                Spacer()
                if anche.handshaked {
                    Text("协议已通")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(themeMgr.color(.ok))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
            }
            if !anche.lastStatus.isEmpty {
                Text(anche.lastStatus)
                    .font(.caption2)
                    .foregroundStyle(anche.handshaked ? themeMgr.color(.ok) : themeMgr.color(.warn))
            }
            Text("写特征: \(obd.txCharDescription)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(themeMgr.secondary)
        }
        .padding(10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 快速操作

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("协议测试")
                .font(.caption.bold())
                .foregroundStyle(themeMgr.secondary)

            HStack(spacing: 8) {
                Button {
                    anche.ping()
                } label: {
                    Label("网络检测", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(themeMgr.color(.ok))
                .disabled(!obd.status.isConnected)

                Button {
                    anche.reset()
                } label: {
                    Label("复位", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(themeMgr.color(.warn))
                .disabled(!obd.status.isConnected)
            }

            // 帧说明
            VStack(alignment: .leading, spacing: 2) {
                Text("网络检测: 00 00 05 00 05")
                Text("复位:     13 00 06 00 03 1C")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(themeMgr.secondary)

            Divider()

            // 手动发
            HStack(spacing: 8) {
                TextField("手动 hex，如 13 00 06 00 03 1C", text: $manualHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button("发") {
                    var bytes: [UInt8] = []
                    let clean = manualHex.replacingOccurrences(of: " ", with: "")
                                         .replacingOccurrences(of: "0x", with: "")
                    var i = clean.startIndex
                    while i < clean.endIndex {
                        let n = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
                        if let b = UInt8(clean[i..<n], radix: 16) { bytes.append(b) }
                        i = n
                    }
                    if !bytes.isEmpty {
                        anche.send(bytes, timeout: 2.0)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(themeMgr.color(.power))
                .disabled(!obd.status.isConnected || manualHex.isEmpty)
            }
        }
        .padding(10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 数据流请求

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("请求数据流（\(AnCheCodeTable.all.count) 个 ID）")
                .font(.caption.bold())
                .foregroundStyle(themeMgr.secondary)

            // 常用几个
            HStack(spacing: 6) {
                ForEach(AnCheCodeTable.common.prefix(6)) { code in
                    Button(code.name) {
                        anche.requestStream(code)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.bordered)
                }
                Spacer()
            }

            // 已读到的值
            if anche.values.isEmpty {
                Text("还没收到数据流响应")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(anche.values.keys.sorted()), id: \.self) { id in
                    HStack(spacing: 6) {
                        Text(id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.rpm))
                        Text(AnCheCodeTable.find(id)?.name ?? "")
                            .font(.caption2)
                            .foregroundStyle(themeMgr.secondary)
                        Spacer()
                        Text(String(format: "%.2f", anche.values[id] ?? 0))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.ok))
                    }
                }
            }
        }
        .padding(10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("收发日志")
                    .font(.caption.bold())
                    .foregroundStyle(themeMgr.secondary)
                Spacer()
                Button {
                    anche.clearLog()
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(themeMgr.color(.warn))

                Button {
                    let dump = (anche.txLog + anche.rxLog).joined(separator: "\n")
                    UIPasteboard.general.string = dump
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(themeMgr.color(.ok))
                .disabled(anche.txLog.isEmpty && anche.rxLog.isEmpty)
            }

            if anche.txLog.isEmpty && anche.rxLog.isEmpty {
                Text("还没有收发记录")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(anche.txLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.warn))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(anche.rxLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.ok))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
