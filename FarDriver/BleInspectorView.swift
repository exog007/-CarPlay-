//
//  BleInspectorView.swift
//  BLE 完整诊断页
//
//  用于逆向私有协议模块：
//    · 列出所有服务 / 特征 / 属性
//    · 手动切换写特征和通知特征
//    · 用多种格式发送（带 \r / 不带 / 加 \n）
//    · 实时看收到的原始字节
//

import SwiftUI
import CoreBluetooth

struct BleInspectorView: View {

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject private var obd = ObdManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var sendText = ""
    /// 发送格式
    @State private var appendCR = true
    @State private var appendLF = false
    /// 是否按 hex 解析
    @State private var asHex = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    statusBar
                    serviceSection
                    sendSection
                    receiveSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
            .navigationTitle("BLE 诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
        .onAppear { obd.dumpCharacteristics() }
    }

    // MARK: - 状态

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(obd.status.isConnected ? themeMgr.color(.ok) : Color.gray)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(obd.status.isConnected ? "已连接" : obd.status.text)
                    .font(.caption.bold())
                    .foregroundStyle(themeMgr.foreground)
                Text(obd.deviceName.isEmpty ? "—" : obd.deviceName)
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
            }
            Spacer()
            Text("\(obd.sniffByteCount) B")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(themeMgr.color(.rpm))
        }
        .padding(10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 服务 / 特征

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("服务与特征")
                    .font(.caption.bold())
                    .foregroundStyle(themeMgr.secondary)
                Spacer()
                Button {
                    obd.dumpCharacteristics()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
            }

            if obd.charList.isEmpty {
                Text("还没发现服务。先连上模块。")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(obd.charList) { item in
                    charRow(item)
                }
            }
        }
        .padding(10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func charRow(_ item: CharInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.serviceUUID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary)
                    .lineLimit(1)
                Spacer()
                if item.isWriteSelected {
                    Text("写")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(themeMgr.color(.rpm))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                if item.isNotifySelected {
                    Text("通知")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(themeMgr.color(.ok))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
            }
            Text(item.uuid)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(themeMgr.foreground)
            HStack(spacing: 4) {
                ForEach(item.properties, id: \.self) { p in
                    Text(p)
                        .font(.system(size: 8))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(themeMgr.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                if item.canWrite {
                    Button("设为写") {
                        obd.selectWrite(uuid: item.uuid)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.bordered)
                    .tint(themeMgr.color(.rpm))
                }
                if item.canNotify {
                    Button("订阅") {
                        obd.selectNotify(uuid: item.uuid)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.bordered)
                    .tint(themeMgr.color(.ok))
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeMgr.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 发送

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发送测试")
                .font(.caption.bold())
                .foregroundStyle(themeMgr.secondary)

            TextField("输入内容，如 ATZ 或 01 0C", text: $sendText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)

            HStack(spacing: 10) {
                Toggle("\\r", isOn: $appendCR)
                    .labelsHidden()
                Text("\\r").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary)
                Toggle("\\n", isOn: $appendLF)
                    .labelsHidden()
                Text("\\n").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary)
                Toggle("十六进制", isOn: $asHex)
                    .font(.caption2)
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    obd.inspectorSend(text: sendText,
                                      asHex: asHex,
                                      appendCR: appendCR,
                                      appendLF: appendLF)
                    obd.dumpCharacteristics()
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(themeMgr.color(.power))
                .disabled(!obd.status.isConnected || sendText.isEmpty)

                Button {
                    obd.resetRxStats()
                } label: {
                    Label("清空接收", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(themeMgr.color(.warn))
            }

            // 常用指令快捷键
            HStack(spacing: 6) {
                ForEach(["ATZ", "ATI", "0100", "010C", "AA 55", "0C"], id: \.self) { c in
                    Button(c) {
                        sendText = c
                        asHex = c.allSatisfy { $0.isHexDigit || $0 == " " }
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 接收

    private var receiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("接收（\(obd.sniffLog.count) 帧）")
                    .font(.caption.bold())
                    .foregroundStyle(themeMgr.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = obd.sniffDump()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(themeMgr.color(.ok))
                .disabled(obd.sniffLog.isEmpty)
            }

            if obd.sniffLog.isEmpty {
                Text("没有收到任何数据。\n\n如果发指令也没回应，说明模块需要特定的握手协议，或者写特征选错了。")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(obd.sniffLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(line.hasPrefix(">>>")
                                             ? themeMgr.color(.warn)
                                             : themeMgr.color(.ok))
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
