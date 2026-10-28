//
//  AntBmsView.swift
//  蚂蚁 BMS 页面
//

import SwiftUI

struct AntBmsView: View {
    @ObservedObject var bms: AntBmsManager
    @ObservedObject var themeMgr: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var showCells = true

    /// 电池化学类型（存在本地，可切换）
    @AppStorage("batteryChemistry") private var chemistryRaw: String = BatteryChemistry.ncm.rawValue
    private var chemistry: BatteryChemistry {
        BatteryChemistry(rawValue: chemistryRaw) ?? .ncm
    }

    /// 手动设的单体满电电压（BMS 读不到时兜底，0 = 没设）
    @AppStorage("manualCellFullVoltage") private var manualCellFull: Double = 0

    /// 健康度（读不到循环次数就是 nil）
    private var soh: Double? {
        guard bms.data.cycles > 0 else { return nil }
        return BatteryHealth.soh(cycles: bms.data.cycles, chemistry: chemistry)
    }

    private var healthLevel: HealthLevel? {
        guard let s = soh else { return nil }
        return HealthLevel.from(soh: s)
    }

    /// 充电中 / 放电中 / 待机
    private var stateText: (String, Color, String) {
        if bms.data.isCharging || bms.smoothedCurrent > 0.5 {
            return ("充电中", themeMgr.color(.ok), "bolt.fill")
        } else if bms.data.isDischarging || bms.smoothedCurrent < -0.5 {
            return ("放电中", themeMgr.color(.power), "bolt.slash.fill")
        }
        return ("待机", themeMgr.color(.warn), "pause.circle.fill")
    }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if bms.connected {
                    if bms.data.hasData {
                        socSection
                        chargeSection
                        bmsConfigSection
                        summarySection
                        healthSection
                        chargingAdviceSection
                        if !bms.data.cells.isEmpty {
                            cellsSection
                        }
                        tempSection
                    } else {
                        summarySection
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
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
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

    // MARK: - BMS 配置（自动读取）

    private var bmsConfigSection: some View {
        Section {
            if bms.bmsConfig.isEmpty {
                // 没读到
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(themeMgr.color(.power))
                        Text("没读到 BMS 配置")
                            .font(.subheadline)
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Button("重试") {
                            bms.reloadConfig()
                        }
                        .font(.caption)
                    }
                    if let e = bms.configError {
                        Text(e)
                            .font(.caption2)
                            .foregroundStyle(themeMgr.color(.power))
                    }
                }
            } else {
                // 读到了
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(themeMgr.color(.ok))
                    Text("已从 BMS 读取")
                        .font(.subheadline.bold())
                        .foregroundStyle(themeMgr.color(.ok))
                    Spacer()
                    Button("重读") {
                        bms.reloadConfig()
                    }
                    .font(.caption)
                }

                configRow("单体过压保护", fmt(bms.bmsConfig.cellOvervoltageProtection, "%.3f", "V"), "cellOVP")
                if bms.bmsConfig.packOvervoltageProtection > 0 {
                    configRow("整包过压保护", fmt(bms.bmsConfig.packOvervoltageProtection, "%.1f", "V"), "packOVP")
                }
                if let c = bms.bmsConfig.capacity {
                    configRow("额定容量", fmt(c, "%.1f", "Ah"), "capacity")
                }
                if bms.bmsConfig.cellNumber > 0 {
                    configRow("串数", "\(bms.bmsConfig.cellNumber) S", "cellNumber")
                }
                if bms.bmsConfig.loadedFields.contains("cellType") {
                    configRow("电芯类型", bms.bmsConfig.cellTypeName, "cellType")
                }
                if bms.bmsConfig.cellUndervoltageProtection > 0 {
                    configRow("单体欠压保护",
                              fmt(bms.bmsConfig.cellUndervoltageProtection, "%.3f", "V"),
                              "cellUVP")
                }
            }

            // 手动兜底
            if bms.bmsConfig.cellFullVoltage == nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("单体满电电压（手动）")
                            .font(.caption)
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        TextField("例如 4.20", value: $manualCellFull, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("V")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Text("BMS 没报出过压保护，这里填一个实际满电的单体电压。\n填 0 表示不设置。")
                        .font(.caption2)
                        .foregroundStyle(themeMgr.secondary)
                }
            }
        } header: {
            Text("BMS 配置")
        } footer: {
            Text("满电电压来源：\(cellFullVoltageSource)。充电阶段判定和剩余时间都用这个值。")
                .font(.caption2)
        }
    }

    private func configRow(_ title: String, _ value: String, _ key: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(themeMgr.foreground)
            Spacer()
            if bms.bmsConfig.loadedFields.contains(key) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(themeMgr.color(.rpm))
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(themeMgr.secondary)
            }
        }
    }

    private func fmt(_ v: Double, _ f: String, _ unit: String) -> String {
        guard v > 0 else { return "—" }
        return String(format: f, v) + " " + unit
    }

    // MARK: - 电量进度条

    private var socSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // 状态 + 百分比
                HStack {
                    Image(systemName: stateText.2)
                        .foregroundStyle(stateText.1)
                    Text(stateText.0)
                        .font(.subheadline.bold())
                        .foregroundStyle(stateText.1)
                    Spacer()
                    Text("\(bms.data.soc)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(socColor)
                    Text("%")
                        .font(.caption)
                        .foregroundStyle(themeMgr.secondary)
                }

                // 进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(themeMgr.isLight
                                  ? Color.black.opacity(0.08)
                                  : Color.white.opacity(0.12))
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [socColor.opacity(0.7), socColor],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * Double(bms.data.soc) / 100.0))
                    }
                }
                .frame(height: 16)

                // 关键刻度标记
                HStack(spacing: 0) {
                    Text("0%").font(.system(size: 8)).foregroundStyle(themeMgr.secondary)
                    Spacer()
                    Text("10%").font(.system(size: 8))
                        .foregroundStyle(bms.data.soc <= 10 ? themeMgr.color(.warn) : themeMgr.secondary)
                        .offset(x: -20)
                    Spacer()
                    Text("20%").font(.system(size: 8))
                        .foregroundStyle(bms.data.soc <= 20 ? themeMgr.color(.power) : themeMgr.secondary)
                    Spacer()
                    Text("80%").font(.system(size: 8))
                        .foregroundStyle(bms.data.soc >= 80 ? themeMgr.color(.ok) : themeMgr.secondary)
                        .offset(x: 12)
                    Spacer()
                    Text("100%").font(.system(size: 8)).foregroundStyle(themeMgr.secondary)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("电量")
        }
    }

    private var socColor: Color {
        if bms.data.soc <= 10 { return themeMgr.color(.warn) }
        if bms.data.soc <= 20 { return themeMgr.color(.power) }
        if bms.data.soc >= 80 { return themeMgr.color(.ok) }
        return themeMgr.color(.rpm)
    }

    // MARK: - 充放电剩余时间

    private var chargeSection: some View {
        Section {
            // 电压 / 电流 / 功率
            HStack(spacing: 0) {
                tripleCell("电压", String(format: "%.1f", bms.data.totalVoltage), "V", themeMgr.color(.voltage))
                Divider().frame(height: 32)
                tripleCell("电流", String(format: "%.1f", bms.smoothedCurrent), "A", themeMgr.color(.current))
                Divider().frame(height: 32)
                tripleCell("功率", "\(Int(abs(bms.data.power)))", "W", themeMgr.color(.power))
            }
            .padding(.vertical, 4)

            // 时间估算
            if let est = chargeEstimate() {
                // 充电阶段标签
                if let ph = est.phase {
                    HStack(spacing: 6) {
                        Image(systemName: phaseIcon(ph))
                            .font(.caption)
                            .foregroundStyle(phaseColor(ph))
                        Text(ph.title)
                            .font(.caption.bold())
                            .foregroundStyle(phaseColor(ph))
                        Spacer()
                        if ph == .cv, let cellV = currentCellVoltage {
                            Text(String(format: "单体 %.3fV", cellV))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(themeMgr.secondary)
                        }
                    }
                    if let hint = ph.hint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(themeMgr.secondary)
                    }
                }

                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(themeMgr.color(.ok))
                    Text("预计剩余")
                        .font(.caption)
                        .foregroundStyle(themeMgr.secondary)
                    Spacer()
                    Text(ChargeEstimator.format(est.remainingSeconds))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(themeMgr.color(.ok))
                }
                // 预计充满时刻
                HStack {
                    Image(systemName: "flag.checkered")
                        .foregroundStyle(themeMgr.color(.ok))
                    Text("预计充满")
                        .font(.caption)
                        .foregroundStyle(themeMgr.secondary)
                    Spacer()
                    Text(finishClock(est.remainingSeconds))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(themeMgr.color(.ok))
                }
                if let note = est.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(themeMgr.color(.power))
                }
                // 按 80% 截止的建议时刻
                if bms.data.soc < 80, let to80 = chargeRemainingTo80() {
                    HStack {
                        Image(systemName: "battery.75percent")
                            .foregroundStyle(themeMgr.color(.power))
                        Text("预计到 80%")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                        Spacer()
                        Text("\(ChargeEstimator.format(to80))（\(finishClock(to80))）")
                            .font(.system(size: 13, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(themeMgr.color(.power))
                    }
                }
            } else if let est = dischargeEstimate() {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(themeMgr.color(.power))
                    Text("预计可骑")
                        .font(.caption)
                        .foregroundStyle(themeMgr.secondary)
                    Spacer()
                    Text(ChargeEstimator.format(est.remainingSeconds))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(themeMgr.color(.power))
                }
                // 预计没电时刻
                HStack {
                    Image(systemName: "flag.checkered")
                        .foregroundStyle(themeMgr.color(.power))
                    Text("预计没电")
                        .font(.caption)
                        .foregroundStyle(themeMgr.secondary)
                    Spacer()
                    Text(finishClock(est.remainingSeconds))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(themeMgr.color(.power))
                }
                if let note = est.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(themeMgr.secondary)
                }
            } else {
                Text("时间是按电流估的，需要 BMS 报出 SOC 和容量")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
            }
        } header: {
            Text("实时读数")
        }
    }

    /// 从现在起 N 秒后是几点 → "12:35"
    private func finishClock(_ seconds: TimeInterval) -> String {
        let target = Date().addingTimeInterval(seconds)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: target)
    }

    private func phaseIcon(_ p: ChargePhase) -> String {
        switch p {
        case .cc:     return "bolt.fill"
        case .ccLate: return "bolt.badge.clock.fill"
        case .cv:     return "waveform.path.ecg"
        }
    }

    private func phaseColor(_ p: ChargePhase) -> Color {
        switch p {
        case .cc:     return themeMgr.color(.ok)
        case .ccLate: return themeMgr.color(.power)
        case .cv:     return themeMgr.color(.voltage)
        }
    }

    /// 充到 80% 还要多久
    private func chargeRemainingTo80() -> TimeInterval? {
        guard bms.smoothedCurrent > 0.5,
              effectiveCapacity > 0,
              bms.data.soc < 80 else { return nil }
        let needAh = Double(80 - bms.data.soc) / 100.0 * effectiveCapacity
        var sec = needAh / bms.smoothedCurrent * 3600.0
        // 和总估算用同一套 CV 修正
        if bms.smoothedCurrent < bms.fullChargeCurrent * 0.5 {
            sec *= 1.7
        }
        return sec
    }

    private func tripleCell(_ title: String, _ value: String, _ unit: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(themeMgr.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(c)
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(themeMgr.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 当前单体平均电压
    private var currentCellVoltage: Double? {
        let v = bms.avgCellVoltage
        return v > 1.0 ? v : nil
    }

    /// 单体满电电压
    /// 优先级：BMS 读到的过压保护值 > 用户手动设的 > 什么都不用（不给默认 4.3）
    private var cellFullVoltage: Double? {
        // ① BMS 上报的过压保护（最权威）
        if let v = bms.bmsConfig.cellFullVoltage { return v }
        // ② 用户手动填的
        if manualCellFull > 2.0 && manualCellFull < 5.0 { return manualCellFull }
        // ③ 都没有就不猜
        return nil
    }

    /// 满电电压的来源说明
    private var cellFullVoltageSource: String {
        if bms.bmsConfig.cellFullVoltage != nil { return "BMS 自动读取" }
        if manualCellFull > 2.0 { return "手动设置" }
        return "未设置"
    }

    /// 电池总容量
    /// 优先用 BMS 配置的额定容量，其次用状态帧里的
    private var effectiveCapacity: Double {
        if let c = bms.bmsConfig.capacity { return c }
        return bms.data.capacityTotal
    }

    private func chargeEstimate() -> ChargeEstimator.Result? {
        guard bms.smoothedCurrent > 0.5 else { return nil }
        guard effectiveCapacity > 0 else { return nil }
        // 没有满电电压就按单体 4.2V 兜底算阶段，但不宣称准确
        let full = cellFullVoltage ?? 4.2
        return ChargeEstimator.chargeRemaining(
            soc: bms.data.soc,
            capacityTotal: effectiveCapacity,
            currentA: bms.smoothedCurrent,
            fullCurrentA: bms.fullChargeCurrent,
            cellVoltage: currentCellVoltage ?? 0,
            cellFull: full,
            voltageHistory: bms.voltageHistory
        )
    }

    private func dischargeEstimate() -> ChargeEstimator.Result? {
        guard bms.smoothedCurrent < -0.5 else { return nil }
        return ChargeEstimator.dischargeRemaining(
            soc: bms.data.soc,
            capacityTotal: bms.data.capacityTotal,
            currentA: bms.smoothedCurrent
        )
    }

    // MARK: - 健康度

    private var healthSection: some View {
        Section {
            if let s = soh, let level = healthLevel {
                VStack(alignment: .leading, spacing: 10) {
                    // 健康度大数字
                    HStack(alignment: .firstTextBaseline) {
                        if level.showsTriangle {
                            Image(systemName: level.triangleIcon)
                                .font(.system(size: 18))
                                .foregroundStyle(level.color)
                        }
                        Text("健康度")
                            .font(.subheadline)
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text(String(format: "%.1f", s))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(level.color)
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                    }

                    // 健康度条（只看 50~100 区间，更直观）
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(themeMgr.isLight
                                      ? Color.black.opacity(0.08)
                                      : Color.white.opacity(0.12))
                            RoundedRectangle(cornerRadius: 6)
                                .fill(level.color)
                                .frame(width: max(4, geo.size.width * max(0, (s - 50) / 50.0)))
                        }
                    }
                    .frame(height: 10)

                    // 底部说明
                    HStack {
                        Text("循环 \(bms.data.cycles) / 寿命 \(chemistry.designCycles) 次")
                            .font(.caption2)
                            .foregroundStyle(themeMgr.secondary)
                        Spacer()
                        Text("\(chemistry.rawValue) · 80% 安全线")
                            .font(.caption2)
                            .foregroundStyle(level.color)
                    }

                    // 预警提示
                    if let msg = level.message {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: level.triangleIcon)
                                .font(.system(size: 16))
                                .foregroundStyle(level.color)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(level.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(level.color.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.vertical, 4)

                // 距离告警还剩多少次
                if level != .critical {
                    HStack {
                        Text("距 70% 还剩")
                        Spacer()
                        Text("\(BatteryHealth.cyclesLeftToCritical(cycles: bms.data.cycles, chemistry: chemistry)) 次循环")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(themeMgr.secondary)
                    }
                }

                // 化学类型切换
                Picker("电池类型", selection: $chemistryRaw) {
                    ForEach(BatteryChemistry.allCases, id: \.rawValue) { c in
                        Text("\(c.rawValue)（\(c.designCycles) 次）").tag(c.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("健康度")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text("—")
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Text("BMS 没有报出循环次数，算不了健康度。\n可以去蚂蚁 App 里看一眼循环次数。")
                        .font(.caption2)
                        .foregroundStyle(themeMgr.color(.power))
                }
            }
        } header: {
            Text("电池健康度")
        } footer: {
            Text("健康度按循环次数推算：健康度 = 100% − (循环次数 ÷ 寿命循环次数) × 20%。这是理论值，实际容量衰减可能略有差异。")
                .font(.caption2)
        }
    }

    // MARK: - 充电建议

    private var chargingAdviceSection: some View {
        Section {
            ForEach(Array(chemistry.chargingAdvice.enumerated()), id: \.offset) { i, advice in
                HStack(spacing: 8) {
                    Image(systemName: adviceIcon(i))
                        .font(.system(size: 13))
                        .foregroundStyle(adviceColor(i))
                        .frame(width: 18)
                    Text(advice)
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
                .padding(.vertical, 2)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("避免老化鼓包等严重影响")
                    .font(.caption2)
            }
            .foregroundStyle(themeMgr.secondary)
            .padding(.top, 4)
        } header: {
            Label("\(chemistry.rawValue)充电建议", systemImage: "lightbulb.fill")
        }
    }

    /// 第 i 条建议是否命中当前 SOC
    private func adviceIsActive(_ i: Int) -> Bool {
        let soc = bms.data.soc
        switch i {
        case 0: return soc >= 80       // 充到 80% 了
        case 1: return soc <= 20       // 到 20% 了
        case 2: return soc <= 10       // 到 10% 了
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
        case 0: return "battery.75percent"
        case 1: return "battery.25percent"
        default: return "battery.0percent"
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
                HStack {
                    Text("串数")
                    Spacer()
                    Text("\(bms.data.cellCount) 串")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(themeMgr.color(.rpm))
                }
                if bms.data.capacityTotal > 0 {
                    HStack {
                        Text("容量")
                        Spacer()
                        Text(String(format: "%.1f / %.1f Ah",
                                    bms.data.capacityRemaining, bms.data.capacityTotal))
                            .font(.system(.caption, design: .monospaced))
                    }
                    HStack {
                        Text("剩余能量")
                        Spacer()
                        Text(String(format: "%.2f kWh",
                                    bms.data.capacityRemaining * bms.data.totalVoltage / 1000.0))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                HStack {
                    Text("单体压差")
                    Spacer()
                    Text(String(format: "%.3f V", bms.data.deltaCell))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(bms.data.deltaCell > 0.05
                                         ? themeMgr.color(.power)
                                         : themeMgr.color(.ok))
                }
            }
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
