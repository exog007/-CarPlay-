//
//  AntBmsView.swift
//  蚂蚁 BMS 页面
//
//  布局照抄原厂 ANT BMS V2：
//    ① 顶部大卡片（环形 SOC + 3×2 数据网格 + 剩余时间）
//    ② 单体极值条（平均 / 最低 / 最高 / 压差）
//    ③ 状态提示卡
//    ④ 温度条（均衡 / MOS / T1~T4）
//    ⑤ 单体电压网格
//
//  原厂的「防拆置位」换成我们算出来的电池健康度。
//  配色跟随 App 主题，不自带颜色。
//

import SwiftUI

struct AntBmsView: View {
    @ObservedObject var bms: AntBmsManager
    @ObservedObject var themeMgr: ThemeManager
    @Environment(\.dismiss) private var dismiss

    /// 电池化学类型（用于健康度寿命计算）
    @AppStorage("batteryChemistry") private var chemistryRaw: String = BatteryChemistry.ncm.rawValue
    private var chemistry: BatteryChemistry {
        BatteryChemistry(rawValue: chemistryRaw) ?? .ncm
    }

    // MARK: - 健康度

    private var soh: Double? {
        guard bms.data.cycles > 0 else { return nil }
        return BatteryHealth.soh(cycles: bms.data.cycles, chemistry: chemistry)
    }

    private var healthLevel: HealthLevel? {
        guard let s = soh else { return nil }
        return HealthLevel.from(soh: s)
    }

    /// 健康度颜色
    private var sohColor: Color {
        healthLevel?.color ?? themeMgr.secondary
    }

    // MARK: - 状态

    /// 充放电状态
    ///
    /// 只看电流正负，不看 MOS 开关状态。
    /// MOS 是「能力开关」，不是「正在发生」——充放电 MOS 都开着是正常的，
    /// 不代表正在充电。官方 App 也是按电流判断的。
    ///
    /// 电流 < -1A → 充电中（负电流 = 电流流进电池）
    /// 电流 >  1A → 放电中（正电流 = 电流流出电池）
    /// 其它       → 待机
    private var stateText: (String, Color, String) {
        let cur = bms.smoothedCurrent
        if cur < -1.0 {
            return ("充电中", themeMgr.color(.ok), "bolt.fill")
        } else if cur > 1.0 {
            return ("放电中", themeMgr.color(.power), "bolt.slash.fill")
        }
        return ("待机", themeMgr.color(.warn), "pause.circle.fill")
    }

    /// 充电 MOS 是否开启（这是能力，不是状态）
    private var chargeMOSOn: Bool { bms.data.isCharging }
    /// 放电 MOS 是否开启
    private var dischargeMOSOn: Bool { bms.data.isDischarging }

    // MOS 开关文字。拆成独立常量，别写成内联三元里的字符串字面量，
    // 否则 Swift 会把它们当成临时对象构造、不落进 __TEXT 常量区。
    private let chargeOnText = "开"
    private let chargeOffText = "关"
    private let dischargeOnText = "开"
    private let dischargeOffText = "关"

    /// BMS 报的电池类型，没有就用用户选的
    private var chemistryLabel: String {
        if bms.data.chemistryCode != 0 { return bms.data.chemistryName }
        return chemistry.rawValue
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    connectionCard

                    // 连上就把所有卡片都画出来
                    // 数据还没到时显示占位符（—），到了自动填上
                    if bms.connected {
                        mainCard          // ① 顶部大卡片
                        cellExtremeCard   // ② 单体极值
                        statusCard        // ③ 状态提示
                        temperatureCard   // ④ 温度
                        cellsCard         // ⑤ 单体电压网格
                        configCard        // BMS 配置
                        adviceCard        // 充电建议
                    }
                    debugCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
            .navigationTitle(bms.connected ? bms.deviceName : "蚂蚁 BMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    // MARK: - 连接卡

    private var connectionCard: some View {
        VStack(spacing: 10) {
            HStack {
                Circle()
                    .fill(bms.connected ? themeMgr.color(.ok) : Color.gray)
                    .frame(width: 9, height: 9)
                Text(bms.connected ? "已连接 \(bms.deviceName)" : "未连接")
                    .font(.subheadline)
                    .foregroundStyle(themeMgr.foreground)
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(bms.connected
                                    ? themeMgr.color(.warn).opacity(0.2)
                                    : themeMgr.color(.rpm))
                        .foregroundStyle(bms.connected ? themeMgr.color(.warn) : Color.white)
                        .clipShape(Capsule())
                }
            }

            if bms.scanning {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("正在搜索…（蚂蚁 BMS 名字通常带 ANT）")
                        .font(.caption2)
                        .foregroundStyle(themeMgr.secondary)
                    Spacer()
                }
            }

            if !bms.connected && !bms.discovered.isEmpty {
                Divider().background(themeMgr.secondary.opacity(0.25))
                VStack(spacing: 6) {
                    ForEach(bms.discovered, id: \.id) { dev in
                        Button {
                            bms.connect(to: dev.id)
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
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(themeMgr.isLight
                                        ? Color.black.opacity(0.05)
                                        : Color.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }

            if let e = bms.errorMsg {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(e)
                        .font(.caption2)
                    Spacer()
                }
                .foregroundStyle(themeMgr.color(.power))
            }
        }
        .padding(14)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    // MARK: - ① 顶部大卡片
    //
    // 没数据时显示「—」，不整卡消失。这样连上就能看到界面框架，
    // 数据一到自动填，不会出现空白页。

    private var voltageText: String {
        guard bms.data.hasData, bms.data.totalVoltage > 0 else { return "—" }
        return String(format: "%.2f", bms.data.totalVoltage)
    }
    private var currentText: String {
        guard bms.data.hasData else { return "—" }
        return String(format: "%.1f", bms.data.current)
    }
    /// 功率（按电流符号取号：负 = 充电，正 = 放电）
    private var powerSign: String {
        guard bms.data.hasData else { return "" }
        return bms.data.power < -1 ? "−" : (bms.data.power > 1 ? "+" : "")
    }
    private var powerText: String {
        guard bms.data.hasData else { return "—" }
        return powerSign + "\(Int(abs(bms.data.power)))"
    }
    private var capacityText: String {
        guard bms.data.capacityTotal > 0 else { return "—" }
        return String(format: "%.0f/%.0f", bms.data.capacityRemaining, bms.data.capacityTotal)
    }
    private var cyclesText: String {
        guard bms.data.cycles > 0 else { return "—" }
        return "\(bms.data.cycles)"
    }
    private var sohText: String {
        soh.map { String(format: "%.0f", $0) } ?? "—"
    }

    private var mainCard: some View {
        VStack(spacing: 0) {
            // 上半：左边环形 SOC，右边 3×2 网格
            HStack(alignment: .top, spacing: 14) {
                socRing
                    .frame(width: 118, height: 118)

                VStack(spacing: 0) {
                    // 第一行：电压 / 电流 / 功率
                    HStack(spacing: 0) {
                        gridCell("电压", voltageText, "V", themeMgr.color(.voltage))
                        gridCell("电流", currentText, "A", themeMgr.color(.current))
                        gridCell("功率", powerText, "W", themeMgr.color(.power))
                    }
                    .padding(.bottom, 10)

                    Divider().background(themeMgr.secondary.opacity(0.2))

                    // 第二行：容量 / 循环 / 健康度（原厂是防拆置位）
                    HStack(spacing: 0) {
                        gridCell("容量", capacityText, "Ah", themeMgr.foreground)
                        gridCell("循环", cyclesText, "次", themeMgr.color(.rpm))
                        gridCell("健康度", sohText, "%", sohColor)
                    }
                    .padding(.vertical, 10)

                    Divider().background(themeMgr.secondary.opacity(0.2))

                    // 第三行：状态（按电流）/ 充电MOS开关 / 放电MOS开关
                    HStack(spacing: 0) {
                        gridCell("状态",
                                 stateText.0,
                                 "", stateText.1)
                        gridCell("充电MOS",
                                 chargeMOSOn ? chargeOnText : chargeOffText,
                                 "",
                                 chargeMOSOn ? themeMgr.color(.ok) : themeMgr.secondary)
                        gridCell("放电MOS",
                                 dischargeMOSOn ? dischargeOnText : dischargeOffText,
                                 "",
                                 dischargeMOSOn ? themeMgr.color(.power) : themeMgr.secondary)
                    }
                    .padding(.top, 10)
                }
            }
            .padding(14)

            Divider().background(themeMgr.secondary.opacity(0.2))

            // 下半：剩余时间
            HStack(spacing: 0) {
                timeCell("充电剩余", bms.data.chargeRemainMin, themeMgr.color(.ok))
                Divider().frame(height: 30)
                timeCell("放电剩余", bms.data.dischargeRemainMin, themeMgr.color(.power))
                Divider().frame(height: 30)
                VStack(spacing: 3) {
                    Text("化学类型")
                        .font(.system(size: 10))
                        .foregroundStyle(themeMgr.secondary)
                    Text(chemistryLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(themeMgr.color(.rpm))
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
        }
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    /// 环形 SOC
    private var socRing: some View {
        let hasSoc = bms.data.hasData
        let ratio = hasSoc ? Double(bms.data.soc) / 100.0 : 0
        return ZStack {
            Circle()
                .stroke(themeMgr.isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.10),
                        lineWidth: 11)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, ratio)))
                .stroke(hasSoc ? socColor : themeMgr.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: ratio)
            VStack(spacing: 1) {
                Text(hasSoc ? "\(bms.data.soc)" : "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(hasSoc ? socColor : themeMgr.secondary)
                Text("%")
                    .font(.system(size: 11))
                    .foregroundStyle(themeMgr.secondary)
            }
        }
    }

    private var socColor: Color {
        if bms.data.soc <= 10 { return themeMgr.color(.warn) }
        if bms.data.soc <= 20 { return themeMgr.color(.power) }
        if bms.data.soc >= 80 { return themeMgr.color(.ok) }
        return themeMgr.color(.rpm)
    }

    /// 3×2 网格里的一格
    private func gridCell(_ title: String, _ value: String, _ unit: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(themeMgr.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(c)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8))
                        .foregroundStyle(themeMgr.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 剩余时间格子
    private func timeCell(_ title: String, _ minutes: Int, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(themeMgr.secondary)
            Text(minutes > 0 ? minutesText(minutes) : "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(minutes > 0 ? c : themeMgr.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func minutesText(_ min: Int) -> String {
        guard min > 0 else { return "—" }
        if min >= 60 { return "\(min / 60)时\(min % 60)分" }
        return "\(min)分"
    }

    // MARK: - ② 单体极值条

    private var cellExtremeCard: some View {
        let hasCells = !bms.data.cells.isEmpty
        return HStack(spacing: 0) {
            extremeCell("平均电压",
                        hasCells ? String(format: "%.3f", bms.data.avgCell) : "—",
                        nil, themeMgr.color(.ok))
            Divider().frame(height: 42)
            extremeCell("最低电压",
                        hasCells ? String(format: "%.3f", bms.data.minCell) : "—",
                        hasCells ? bms.data.minCellIndex : nil,
                        themeMgr.color(.voltage))
            Divider().frame(height: 42)
            extremeCell("最高电压",
                        hasCells ? String(format: "%.3f", bms.data.maxCell) : "—",
                        hasCells ? bms.data.maxCellIndex : nil,
                        themeMgr.color(.warn))
            Divider().frame(height: 42)
            extremeCell("压差",
                        hasCells ? String(format: "%.3f", bms.data.deltaCell) : "—",
                        nil,
                        hasCells
                        ? (bms.data.deltaCell > 0.05 ? themeMgr.color(.warn) : themeMgr.color(.ok))
                        : themeMgr.secondary)
        }
        .padding(.vertical, 12)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    private func extremeCell(_ title: String, _ value: String, _ index: Int?, _ c: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(themeMgr.secondary)
            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(c)
                if let i = index, i > 0 {
                    Text("#\(i)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(c.opacity(0.2))
                        .foregroundStyle(c)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - ③ 状态提示

    private var statusCard: some View {
        VStack(spacing: 8) {
            // 健康度告警（如果有）
            if let level = healthLevel, level.showsTriangle, let msg = level.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: level.triangleIcon)
                        .font(.system(size: 15))
                        .foregroundStyle(level.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("健康度 \(String(format: "%.0f", soh ?? 0))%")
                            .font(.caption.bold())
                            .foregroundStyle(level.color)
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(level.color.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(level.color.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // 正常状态
            if !isAnyWarning {
                statusRow("checkmark.shield.fill",
                          "系统正常",
                          themeMgr.color(.ok))
            }

            // 充电 / 放电 MOS
            statusRow(bms.data.isCharging ? "bolt.fill" : "bolt.slash.fill",
                      bms.data.isCharging ? "充电 MOS 开" : "充电 MOS 关",
                      bms.data.isCharging ? themeMgr.color(.ok) : themeMgr.secondary)

            // 均衡状态
            if bms.data.balancingActive {
                statusRow("arrow.left.arrow.right.circle.fill",
                          "正在均衡",
                          themeMgr.color(.rpm))
            }

            // 保护标识
            if bms.data.protectionStatus != 0 {
                statusRow("exclamationmark.triangle.fill",
                          String(format: "保护位 0x%08X", bms.data.protectionStatus),
                          themeMgr.color(.warn))
            }
        }
        .padding(12)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    private var isAnyWarning: Bool {
        bms.data.protectionStatus != 0
            || (healthLevel?.showsTriangle ?? false)
    }

    private func statusRow(_ icon: String, _ text: String, _ c: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(c)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(c)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - ④ 温度条

    private var temperatureCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // 均衡温度
                tempCell("均衡", bms.data.temps.isEmpty ? nil : mosBalanceTemp, themeMgr.color(.rpm))
                Divider().frame(height: 34)
                // MOS 温度
                tempCell("MOS", bms.data.mosTemp, bms.data.mosTemp > 60 ? themeMgr.color(.warn) : themeMgr.color(.power))
                // 各电芯温度
                ForEach(Array(bms.data.temps.enumerated()), id: \.offset) { idx, t in
                    Divider().frame(height: 34)
                    tempCell("T\(idx + 1)", t, t > 55 ? themeMgr.color(.warn) : themeMgr.color(.current))
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
        }
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    /// 均衡温度：BMS 报的第一个温度后面那个，没有就退回第一个
    private var mosBalanceTemp: Int {
        bms.data.temps.first ?? 0
    }

    private func tempCell(_ title: String, _ value: Int?, _ c: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(themeMgr.secondary)
            Text(value.map { "\($0)°" } ?? "—")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(c)
        }
        .frame(width: 58)
    }

    // MARK: - ⑤ 单体电压网格

    private var cellsCard: some View {
        let hasCells = !bms.data.cells.isEmpty
        // 没数据时先画 21 个空槽，等数据来了再填
        let placeholderCount = 21
        let displayCells: [(Int, Double)] = hasCells
            ? bms.data.cells.enumerated().map { ($0.offset + 1, $0.element) }
            : (1...placeholderCount).map { ($0, 0.0) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("单体电压")
                    .font(.subheadline.bold())
                    .foregroundStyle(themeMgr.foreground)
                Text(hasCells ? "\(bms.data.cellCount) 串" : "等待数据")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
                Spacer()
                if hasCells {
                    Text(String(format: "%.3f V 平均", bms.data.avgCell))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(themeMgr.secondary)
                }
            }

            LazyVGrid(columns: cellColumns, spacing: 10) {
                ForEach(displayCells, id: \.0) { idx, v in
                    cellChip(index: idx, voltage: v, placeholder: !hasCells)
                }
            }
        }
        .padding(14)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    private var cellColumns: [GridItem] {
        let n = max(bms.data.cellCount, 21)
        let cols: Int
        switch n {
        case 0...8:   cols = 4
        case 9...16:  cols = 4
        case 17...24: cols = 6
        default:      cols = 8
        }
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: cols)
    }

    private func cellChip(index: Int, voltage: Double, placeholder: Bool = false) -> some View {
        let invalid = placeholder || voltage < 1.0
        let isMax = !placeholder && index == bms.data.maxCellIndex
        let isMin = !placeholder && index == bms.data.minCellIndex
        let c: Color = invalid ? themeMgr.secondary.opacity(0.5)
            : (isMax ? themeMgr.color(.warn) : (isMin ? themeMgr.color(.voltage) : themeMgr.color(.current)))
        return VStack(spacing: 3) {
            // 电池小图标 + 编号
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(c.opacity(invalid ? 0.35 : 0.6), lineWidth: 1.2)
                    .frame(width: 24, height: 34)
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(c)
                // 电池正极小凸起
                Rectangle()
                    .fill(c.opacity(invalid ? 0.35 : 0.6))
                    .frame(width: 8, height: 2)
                    .offset(y: -18)
            }
            Text(invalid ? "--" : String(format: "%.3f", voltage))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(c)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(invalid ? Color.clear
                      : (isMax || isMin ? c.opacity(0.10) : Color.clear))
        )
    }

    // MARK: - BMS 配置

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: bms.bmsConfig.isEmpty
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(bms.bmsConfig.isEmpty
                                     ? themeMgr.color(.warn)
                                     : themeMgr.color(.ok))
                Text(bms.bmsConfig.isEmpty ? "没读到 BMS 配置" : "BMS 配置")
                    .font(.caption.bold())
                    .foregroundStyle(themeMgr.foreground)
                Spacer()
                Button("重读") { bms.reloadConfig() }
                    .font(.caption)
            }

            if let e = bms.configError {
                Text(e)
                    .font(.caption2)
                    .foregroundStyle(themeMgr.color(.warn))
            }

            if bms.bmsConfig.cellOvervoltageProtection > 0 {
                configLine("单体过压保护",
                           String(format: "%.3f V", bms.bmsConfig.cellOvervoltageProtection))
            }
            if bms.bmsConfig.packOvervoltageProtection > 0 {
                configLine("整包过压保护",
                           String(format: "%.1f V", bms.bmsConfig.packOvervoltageProtection))
            }
            if bms.bmsConfig.cellUndervoltageProtection > 0 {
                configLine("单体欠压保护",
                           String(format: "%.3f V", bms.bmsConfig.cellUndervoltageProtection))
            }
            if bms.bmsConfig.cellNumber > 0 {
                configLine("串数", "\(bms.bmsConfig.cellNumber) S")
            }
        }
        .padding(12)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    private func configLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(themeMgr.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(themeMgr.color(.rpm))
        }
    }

    // MARK: - 充电建议

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(chemistry.chargingAdvice.enumerated()), id: \.offset) { i, text in
                HStack(spacing: 8) {
                    Image(systemName: adviceIcon(i))
                        .font(.system(size: 12))
                        .foregroundStyle(adviceColor(i))
                        .frame(width: 18)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(adviceColor(i))
                    Spacer()
                    if adviceIsActive(i) {
                        Text("现在")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(adviceColor(i))
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                    }
                }
            }
            Text("避免老化鼓包等严重影响")
                .font(.caption2)
                .foregroundStyle(themeMgr.secondary)
                .padding(.top, 2)
        }
        .padding(12)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }

    private func adviceIsActive(_ i: Int) -> Bool {
        let soc = bms.data.soc
        switch i {
        case 0: return soc >= 80
        case 1: return soc <= 20
        case 2: return soc <= 10
        default: return false
        }
    }

    private func adviceColor(_ i: Int) -> Color {
        let active = adviceIsActive(i)
        switch i {
        case 2: return active ? themeMgr.color(.warn) : themeMgr.secondary
        case 1: return active ? themeMgr.color(.power) : themeMgr.secondary
        default: return active ? themeMgr.color(.ok) : themeMgr.secondary
        }
    }

    private func adviceIcon(_ i: Int) -> String {
        switch i {
        case 0: return "battery.100"
        case 1: return "battery.50"
        default: return "battery.0"
        }
    }

    // MARK: - 调试

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("调试")
                    .font(.caption.bold())
                    .foregroundStyle(themeMgr.secondary)
                Spacer()
                Button("立刻请求一次") { bms.requestNow() }
                    .font(.caption)
            }
            HStack {
                Text("已收帧数")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
                Spacer()
                Text("\(bms.framesReceived)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary)
            }
            if !bms.rawFrameHex.isEmpty {
                Text(bms.rawFrameHex)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary.opacity(0.7))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeMgr.cardStroke, lineWidth: 1)
        }
    }
}
