//
//  AntBmsView.swift
//  蚂蚁 BMS 页面
//

import SwiftUI

struct AntBmsView: View {
    @ObservedObject var bms: AntBmsManager
    @Environment(\.dismiss) private var dismiss
    @State private var showCells = true

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if bms.connected {
                    summarySection
                    if bms.data.hasData {
                        if !bms.data.cells.isEmpty {
                            cellsSection
                        }
                        tempSection
                    }
                    debugSection
                }
            }
            .navigationTitle("蚂蚁 BMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onDisappear {
                // 不主动断开，让它在后台继续读
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 连接

    private var connectionSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(bms.connected ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(bms.connected ? "已连接 \(bms.deviceName)" : "未连接")
                    .font(.subheadline)
                Spacer()
                Button {
                    if bms.connected {
                        bms.disconnect()
                    } else if bms.scanning {
                        bms.stopScan()
                    } else {
                        bms.startScan()
                    }
                } label: {
                    Text(bms.connected ? "断开" : (bms.scanning ? "停止" : "搜索 BMS"))
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(bms.connected ? Color.red.opacity(0.2) : Color.blue)
                        .foregroundStyle(bms.connected ? Color.red : Color.white)
                        .clipShape(Capsule())
                }
            }

            if bms.scanning {
                HStack {
                    ProgressView()
                    Text("正在搜索…（蚂蚁 BMS 名字通常带 ANT）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !bms.connected && !bms.discovered.isEmpty {
                ForEach(bms.discovered, id: \.id) { dev in
                    Button {
                        bms.connect(to: dev.id)
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
                        .padding(.vertical, 4)
                    }
                }
            }

            if let e = bms.errorMsg {
                Text(e)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 概要

    private var summarySection: some View {
        Section("电池概况") {
            if !bms.data.hasData {
                HStack {
                    ProgressView()
                    Text("等待 BMS 回数据…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                bigRow("总电压", String(format: "%.2f", bms.data.totalVoltage), "V", .yellow)
                bigRow("电流", String(format: "%.1f", bms.data.current), "A",
                       bms.data.current < 0 ? .green : .mint)
                bigRow("SOC", "\(bms.data.soc)", "%", .cyan)

                HStack {
                    Text("状态")
                    Spacer()
                    if bms.data.isCharging {
                        Text("充电中")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.green.opacity(0.25))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    } else if bms.data.isDischarging {
                        Text("放电中")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.25))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    } else {
                        Text("待机").font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("串数")
                    Spacer()
                    Text("\(bms.data.cellCount) 串")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
                if bms.data.cycles > 0 {
                    HStack {
                        Text("循环次数")
                        Spacer()
                        Text("\(bms.data.cycles) 次")
                            .font(.system(.subheadline, design: .monospaced))
                    }
                }
                if bms.data.capacityTotal > 0 {
                    HStack {
                        Text("容量")
                        Spacer()
                        Text(String(format: "%.1f / %.1f Ah",
                                    bms.data.capacityRemaining, bms.data.capacityTotal))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }

    private func bigRow(_ title: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 单体电压（自适应串数）

    private var cellsSection: some View {
        Section {
            // 压差摘要
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最高 \(String(format: "%.3f", bms.data.maxCell))V")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    Text("#\(bms.data.maxCellIndex)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(String(format: "压差 %.3fV", bms.data.deltaCell))
                        .font(.subheadline.bold())
                        .foregroundStyle(deltaColor)
                    Text(deltaAdvice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("最低 \(String(format: "%.3f", bms.data.minCell))V")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Text("#\(bms.data.minCellIndex)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            // 单体网格：自动按串数排列
            LazyVGrid(columns: cellColumns, spacing: 6) {
                ForEach(Array(bms.data.cells.enumerated()), id: \.offset) { idx, v in
                    cellBox(index: idx + 1, voltage: v)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("单体电压（\(bms.data.cellCount) 串）")
        } footer: {
            Text("红=最高  绿=最低  灰=电压异常或读不到")
                .font(.caption2)
        }
    }

    /// 串数少就多列，串数多就少列，自动适配
    private var cellColumns: [GridItem] {
        let n = bms.data.cellCount
        let cols: Int
        switch n {
        case 0...8:   cols = 4
        case 9...16:  cols = 4
        case 17...24: cols = 6
        default:      cols = 8
        }
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: cols)
    }

    private func cellBox(index: Int, voltage: Double) -> some View {
        let isMax = index == bms.data.maxCellIndex
        let isMin = index == bms.data.minCellIndex
        let invalid = voltage < 1.0
        return VStack(spacing: 1) {
            Text("\(index)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(invalid ? "--" : String(format: "%.3f", voltage))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(invalid ? Color.secondary : (isMax ? Color.red : (isMin ? Color.green : Color.cyan)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(invalid ? Color(white: 0.15)
                      : (isMax ? Color.red.opacity(0.18)
                         : (isMin ? Color.green.opacity(0.18) : Color(white: 0.13))))
        )
    }

    private var deltaColor: Color {
        let d = bms.data.deltaCell
        if d > 0.08 { return .red }
        if d > 0.04 { return .orange }
        return .green
    }

    private var deltaAdvice: String {
        let d = bms.data.deltaCell
        if d > 0.08 { return "必须均衡" }
        if d > 0.04 { return "建议均衡" }
        return "正常"
    }

    // MARK: - 温度

    private var tempSection: some View {
        Section("温度") {
            ForEach(Array(bms.data.temps.enumerated()), id: \.offset) { i, t in
                HStack {
                    Text("传感器 \(i + 1)")
                    Spacer()
                    Text("\(t)")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(t > 55 ? Color.red : (t > 45 ? Color.orange : Color.cyan))
                    Text("°C").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 调试

    private var debugSection: some View {
        Section {
            HStack {
                Text("已收帧数")
                Spacer()
                Text("\(bms.framesReceived)")
                    .font(.system(.subheadline, design: .monospaced))
            }
            if let t = bms.lastResponseAt {
                HStack {
                    Text("最后响应")
                    Spacer()
                    Text(t.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                }
            }
            if !bms.rawFrameHex.isEmpty {
                Text(bms.rawFrameHex)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button("立刻请求一次") {
                bms.requestNow()
            }
        } header: {
            Text("调试")
        } footer: {
            Text("如果一直显示「等待 BMS 回数据」，说明协议不匹配。把上面的原始帧发我，我对照改。")
                .font(.caption2)
        }
    }
}
