//
//  ObdGridView.swift
//  OBD2 竖屏数据查看页
//
//  把当前读到的所有 PID 数据按网格排开，一屏看全。
//  数据来源是 ObdValueStore（通用仓库，包含界面上暂时不用的值）。
//

import SwiftUI

struct ObdGridView: View {

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject private var store = ObdValueStore.shared
    @ObservedObject private var obd = ObdManager.shared
    @Environment(\.dismiss) private var dismiss

    /// 是否只显示「有值」的项目
    @State private var hideEmpty = false
    /// 行程统计喂数据定时器
    @State private var tripFeedTimer: Timer?
    /// 搜索关键字
    @State private var keyword = ""

    /// 展示列表：车支持的 PID，有值就填值，没值显示 —
    private var items: [Item] {
        // 展示范围：
        //   · 车声明支持的（supportedCodes）
        //   · 已经读到过值的（store 里有）
        // 两者合并，没读到 0100 时退回全部
        let supported = obd.supportedCodes
        let hasValue = Set(store.values.keys)

        var codes: [String]
        if supported.isEmpty && hasValue.isEmpty {
            // 还没握手完，先展示全部（显示 —）
            codes = ObdPidTable.all.map { $0.code }
        } else {
            codes = ObdPidTable.all.map { $0.code }.filter { c in
                supported.contains(c) || hasValue.contains(c)
            }
        }

        // 按 ID 排序，稳定不跳
        codes.sort()

        var list: [Item] = []
        for code in codes {
            guard let def = ObdPidTable.def(code) else { continue }
            let v = store.values[code]
            let item = Item(code: code, name: def.name, unit: def.unit,
                            value: v?.value, updatedAt: v?.updatedAt)
            if hideEmpty && item.value == nil { continue }
            if !keyword.isEmpty {
                let k = keyword.lowercased()
                if !code.lowercased().contains(k) && !def.name.lowercased().contains(k) { continue }
            }
            list.append(item)
        }
        return list
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // 连接状态条
                    HStack(spacing: 8) {
                        Circle()
                            .fill(obd.status.isConnected ? themeMgr.color(.ok) : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(obd.status.isConnected
                             ? "已连接 · 支持 \(obd.supportedCodes.count) 项 · 已读到 \(store.values.count) 项"
                             : obd.status.text)
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                        Spacer()
                        Toggle("只看有值", isOn: $hideEmpty)
                            .labelsHidden()
                            .scaleEffect(0.8)
                    }
                    .padding(.horizontal, 4)

                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "car.side")
                                .font(.system(size: 36))
                                .foregroundStyle(themeMgr.secondary.opacity(0.5))
                            Text(obd.status.isConnected ? "还没有数据" : "未连接 OBD2")
                                .font(.subheadline)
                                .foregroundStyle(themeMgr.secondary)
                            Text(obd.status.isConnected
                                 ? "等几秒让轮询跑一轮"
                                 : "去设置里连上适配器")
                                .font(.caption2)
                                .foregroundStyle(themeMgr.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(items) { it in
                                dataCard(it)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .searchable(text: $keyword, prompt: "搜索名称或 PID")
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
            .navigationTitle("OBD2 数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        
            .onAppear {
                // 数据页要求全量读取
                obd.fullPolling = true
                // 停在数据页时也要继续累计里程和油耗
                startTripFeeding()
            }
            .onDisappear {
                // 退出后恢复只读仪表 7 项，保证竞技仪表刷新率
                obd.fullPolling = false
                stopTripFeeding()
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    // MARK: - 行程统计

    /// 停在数据页时也继续累计里程和油耗
    ///
    /// 和竞技仪表用同一套逻辑：速度来源选哪个都算。
    private func startTripFeeding() {
        guard tripFeedTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { _ in
            let kmh: Double
            if DataSource.current == .motorcycle {
                kmh = GpsSpeed.shared.smoothSpeed
            } else {
                switch SpeedSource.current {
                case .gps: kmh = GpsSpeed.shared.smoothSpeed
                case .obd: kmh = obd.lastObdSpeed
                }
            }
            let rpm = obd.reading.rpm ?? 0
            guard kmh >= 0, !(kmh == 0 && rpm == 0) else { return }
            TripMeter.shared.update(speedKmh: kmh, powerW: 0, rpm: rpm)
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        tripFeedTimer = t
    }

    private func stopTripFeeding() {
        tripFeedTimer?.invalidate()
        tripFeedTimer = nil
    }

    // MARK: - 数据卡片

    private func dataCard(_ it: Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 名称 + PID
            HStack(spacing: 4) {
                Text(it.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(themeMgr.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(it.code.suffix(2))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary.opacity(0.6))
            }

            // 数值 + 单位
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(it.valueText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(it.value == nil
                                     ? themeMgr.secondary.opacity(0.4)
                                     : themeMgr.color(.ok))
                if !it.unit.isEmpty {
                    Text(it.unit)
                        .font(.system(size: 10))
                        .foregroundStyle(themeMgr.secondary)
                }
                Spacer(minLength: 0)
            }

            // 更新时间（有值的显示「x秒前」）
            Text(it.ageText)
                .font(.system(size: 8))
                .foregroundStyle(themeMgr.secondary.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeMgr.isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.08),
                        lineWidth: 1)
        }
    }

    // MARK: - 模型

    struct Item: Identifiable {
        let code: String
        let name: String
        let unit: String
        let value: Double?
        let updatedAt: Date?
        var id: String { code }

        var valueText: String {
            guard let v = value else { return "—" }
            // 按量级决定小数位
            let absV = abs(v)
            if absV >= 1000 { return String(format: "%.0f", v) }
            if absV >= 100 { return String(format: "%.1f", v) }
            return String(format: "%.2f", v)
        }

        var ageText: String {
            guard let t = updatedAt else { return "无数据" }
            let s = Int(Date().timeIntervalSince(t))
            if s < 2 { return "刚刚" }
            if s < 60 { return "\(s) 秒前" }
            return "\(s / 60) 分前"
        }
    }
}
