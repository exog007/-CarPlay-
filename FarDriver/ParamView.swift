//
//  ParamView.swift
//  控制器参数查看（只读）
//
//  ⚠️ 本页只读取控制器主动上报的寄存器内容，不发送任何写入指令。
//     参数能不能改，取决于远驱服务器授权，本 App 不涉及。
//

import SwiftUI

struct ParamView: View {
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager
    @Environment(\.dismiss) private var dismiss

    /// 精简模式 / 专业模式
    @State private var expertMode = false

    private var groups: [ParamGroup] {
        expertMode ? ControllerParams.expertGroups : ControllerParams.simpleGroups
    }

    var body: some View {
        PasswordGate(title: "控制器参数") {
            NavigationStack {
                List {
                    // 模式切换
                    Section {
                        Picker("模式", selection: $expertMode) {
                            Text("精简模式").tag(false)
                            Text("专业模式").tag(true)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(expertMode
                             ? "专业模式：显示全部参数分组（只读）"
                             : "精简模式：只显示常用参数（只读）")
                    }

                    // 连接状态提示
                    if !mgr.status.isConnected {
                        Section {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("还没连上控制器，先去主页连接")
                                    .font(.caption)
                            }
                        }
                    }

                    // 自学习入口
                    // ⚠️ 已隐藏。原因：自学习指令的字节格式未经验证
                    //    （官方 App 是 Xamarin AOT 编译，组包逻辑无法从二进制还原）
                    //    代码完整保留在 SelfLearnView.swift 和 FarDriverCommand.swift
                    //    拿到官方 App 的 BLE 写入日志后，把下面改成 true 就能恢复。
                    if SelfLearnSwitch.visible {
                        Section {
                            NavigationLink {
                                SelfLearnView(mgr: mgr)
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundStyle(.orange)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("电机自学习")
                                        Text("相序 / 角度自动识别")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("调试")
                        }
                    }

                    // 参数分组
                    Section("参数分组") {
                        ForEach(groups) { g in
                            NavigationLink {
                                ParamDetailView(group: g, mgr: mgr, themeMgr: themeMgr)
                            } label: {
                                HStack {
                                    Image(systemName: iconFor(g.title))
                                        .foregroundStyle(themeMgr.color(.rpm))
                                        .frame(width: 22)
                                    Text(g.title)
                                    Spacer()
                                    Text("\(g.items.count) 项")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // 原始数据（调试用）
                    Section {
                        NavigationLink {
                            RawFramesView(mgr: mgr, themeMgr: themeMgr)
                        } label: {
                            HStack {
                                Image(systemName: "number.square")
                                    .foregroundStyle(themeMgr.color(.power))
                                Text("原始寄存器数据")
                                Spacer()
                                Text("\(mgr.receivedFrameCount) 帧")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("调试")
                    } footer: {
                        Text("查看控制器直接上报的原始字节，用来对照官方 App 排查")
                    }
                }
                .navigationTitle("控制器参数")
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

    private func iconFor(_ title: String) -> String {
        switch title {
        case "电机":     return "engine.combustion"
        case "电流":     return "bolt.fill"
        case "油门":     return "hand.tap"
        case "弱磁":     return "bolt.circle"
        case "三档":     return "gauge.with.dots.needle.67percent"
        case "能量回馈": return "arrow.down.circle"
        case "保护":     return "shield.lefthalf.filled"
        case "功能脚":   return "point.3.connected.trianglepath.dotted"
        case "刹车":     return "octagon"
        case "仪表与轮胎": return "gauge.medium"
        case "传感器":   return "thermometer.medium"
        default:         return "square.grid.2x2"
        }
    }
}

// MARK: - 分组详情

struct ParamDetailView: View {
    let group: ParamGroup
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager

    var body: some View {
        List {
            Section {
                ForEach(group.items) { item in
                    HStack {
                        Text(item.title)
                            .font(.subheadline)
                        Spacer()
                        Text(valueText(for: item))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(valueText(for: item) == "—"
                                             ? Color.secondary
                                             : themeMgr.color(.rpm))
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("只读显示。参数由控制器主动上报，本 App 不发送写入指令。\n显示「—」表示还没有收到对应数据。")
                    .font(.caption2)
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    private func valueText(for item: ParamItem) -> String {
        // 目前参数名到帧号/偏移的映射还没有可靠依据，
        // 所以先显示「—」，等抓到官方 App 的数据包再补上映射
        return "—"
    }
}

// MARK: - 原始帧

struct RawFramesView: View {
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager

    var body: some View {
        List {
            if mgr.allFrames.isEmpty {
                Section {
                    Text("还没收到任何数据帧")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(mgr.allFrames, id: \.id) { frame in
                    Section {
                        HStack {
                            Text("帧 \(frame.id)")
                                .font(.caption.bold())
                                .foregroundStyle(themeMgr.color(.power))
                            Text(String(format: "地址 0x%02X", frame.address))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(hexString(frame.bytes))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeMgr.color(.rpm))
                    }
                }
            }
        }
        .navigationTitle("原始寄存器")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    private func hexString(_ bytes: [UInt8]) -> String {
        bytes.enumerated().map { i, b in
            let s = String(format: "%02X", b)
            return (i + 1) % 4 == 0 ? s + "  " : s + " "
        }.joined()
    }
}
