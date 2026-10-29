//
//  SportDashView.swift
//  竞技风格横屏仪表（EVA 诊断屏风格）
//
//  - 纯黑底（或自定义图片）+ 琥珀色单色线框
//  - 转速按用户设置的倍率放大显示（原厂 100rpm → 1000rpm）
//  - 右下角指针式电量表，按电压阈值算百分比
//

import SwiftUI

struct SportDashView: View {
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager
    @ObservedObject var gps: GpsSpeed

    /// 融合车速
    private var speed: Double {
        gps.fused(with: mgr.data.speed)
    }

    private var theme: AppTheme { themeMgr.theme }

    /// 放大后的转速
    private var displayRpm: Double {
        mgr.data.rpm * theme.rpmMultiplier
    }

    /// 转速百分比
    private var rpmRatio: Double {
        guard theme.rpmScaleMax > 0 else { return 0 }
        return min(max(displayRpm / theme.rpmScaleMax, 0), 1)
    }

    /// 电量百分比（按电压阈值线性插值）
    private var batteryPercent: Double {
        BatteryPercent.compute(voltage: mgr.data.voltage,
                               full: theme.battFullVoltage,
                               empty: theme.battEmptyVoltage)
    }

    private var amber: Color { themeMgr.color(.power) }
    private var cyan: Color { themeMgr.color(.rpm) }
    private var red: Color { themeMgr.color(.warn) }

    var body: some View {
        VStack(spacing: 6) {
            topBar
            rpmBand
            middleRow
            bottomRow
        }
        .padding(10)
        .background(sportBackground)
    }

    // MARK: - 背景

    @ViewBuilder
    private var sportBackground: some View {
        if let img = themeMgr.sportPhotoImage {
            ZStack {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: CGFloat(theme.sportPhotoBlur))
                    .clipped()
                Color.black.opacity(theme.sportPhotoDim)
            }
            .ignoresSafeArea()
        } else {
            Color(hex: theme.sportBgHex)
                .ignoresSafeArea()
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(red)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text("车辆状态诊断")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(amber)
                        // 连上控制器后，在标题旁边亮「正常」
                        if mgr.status.isConnected {
                            Text("正常")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(themeMgr.color(.ok))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    Text("VEHICLE DIAGNOSTIC")
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(amber.opacity(0.55))
                }
            }

            Spacer(minLength: 6)

            Text(nowText())
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(amber)
                .padding(.horizontal, 6)

            Spacer(minLength: 6)

            dashPill("DIAGNOSTIC", on: mgr.status.isConnected)
            dashPill("SETTINGS", on: true)
        }
        .frame(height: 30)
    }

    private func nowText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    private func dashPill(_ title: String, on: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(on ? cyan : amber.opacity(0.3))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 7, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(on ? cyan : amber.opacity(0.45))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(on ? cyan.opacity(0.7) : amber.opacity(0.25), lineWidth: 1)
        }
    }

    // MARK: - 转速带

    private var rpmBand: some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: -2) {
                Text("ENGINE  RPM / 转速")
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(amber.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(displayRpm.rounded()))")
                        .font(.system(size: 30, weight: .heavy, design: .monospaced))
                        .foregroundStyle(amber)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("rpm")
                        .font(.system(size: 9))
                        .foregroundStyle(amber.opacity(0.6))
                }
            }
            .frame(width: 130, alignment: .leading)

            VStack(spacing: 2) {
                HStack(spacing: 1.5) {
                    ForEach(0..<40, id: \.self) { i in
                        Rectangle()
                            .fill(amber.opacity(0.25))
                            .frame(width: 2, height: i % 2 == 0 ? 5 : 3)
                    }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(amber.opacity(0.12))
                        Rectangle()
                            .fill(red.opacity(0.22))
                            .frame(width: g.size.width * 0.25)
                            .offset(x: g.size.width * 0.75)
                        Rectangle()
                            .fill(rpmRatio > 0.85 ? red : amber)
                            .frame(width: max(0, g.size.width * rpmRatio))
                        HStack(spacing: 0) {
                            ForEach(0..<20, id: \.self) { _ in
                                Rectangle().fill(.clear)
                                Rectangle().fill(Color.black.opacity(0.85)).frame(width: 2)
                            }
                        }
                    }
                }
                .frame(height: 12)
                .animation(.easeOut(duration: 0.12), value: rpmRatio)

                HStack(spacing: 0) {
                    ForEach(scaleLabels, id: \.self) { n in
                        Text("\(Int(n))")
                            .font(.system(size: 6, weight: .medium, design: .monospaced))
                            .foregroundStyle(amber.opacity(0.5))
                        if n != scaleLabels.last { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .frame(height: 50)
    }

    /// 刻度数字，跟着满量程走
    private var scaleLabels: [Double] {
        let maxV = theme.rpmScaleMax
        return stride(from: 0, through: maxV, by: maxV / 6).map { $0 }
    }

    // MARK: - 中间：速度 + 档位 + 油表

    private var middleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(spacing: 4) {
                Circle()
                    .fill(mgr.status.isConnected ? themeMgr.color(.ok) : amber.opacity(0.25))
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle().stroke(.white.opacity(0.5), lineWidth: 0.5)
                    }
                Rectangle()
                    .fill(amber.opacity(0.3))
                    .frame(width: 1, height: 26)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(Int(speed.rounded()))")
                    .font(.system(size: 68, weight: .heavy, design: .monospaced))
                    .foregroundStyle(amber)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .shadow(color: amber.opacity(theme.sportGlow * 0.9), radius: 10)
                Text("km/h")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(amber.opacity(0.75))
            }

            Spacer(minLength: 0)

            gearBoxes

            Spacer(minLength: 0)

            fuelGauge
                .frame(width: 92, height: 62)
        }
        .frame(maxHeight: .infinity)
    }

    private var isParked: Bool {
        guard mgr.status.isConnected else { return false }
        return speed < 1.0 && abs(mgr.data.current) < 0.5
    }

    private var gearBoxes: some View {
        HStack(spacing: 6) {
            Text("P")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(isParked ? Color.black : amber.opacity(0.35))
                .frame(width: 24, height: 24)
                .background(isParked ? red : Color.clear)
                .overlay {
                    Rectangle().stroke(amber.opacity(0.5), lineWidth: 1)
                }
            ForEach(1...3, id: \.self) { g in
                Text("\(g)")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(mgr.data.gear == g && !isParked
                                     ? Color.black
                                     : amber.opacity(mgr.data.gear == 0 ? 0.2 : 0.6))
                    .frame(width: 24, height: 24)
                    .background(mgr.data.gear == g && !isParked ? amber : Color.clear)
                    .overlay {
                        Rectangle().stroke(amber.opacity(0.45), lineWidth: 1)
                    }
            }
        }
    }

    // MARK: - 指针式电量表

    private var fuelGauge: some View {
        ZStack {
            // 表盘弧：从 150° 到 30°（下半圈留空）
            Circle()
                .trim(from: 0, to: 0.667)
                .stroke(amber.opacity(0.18),
                        style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(150))
            // 已用电量（从空到当前）
            Circle()
                .trim(from: 0, to: 0.667 * batteryPercent)
                .stroke(batteryColor,
                        style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(150))
                .animation(.easeOut(duration: 0.3), value: batteryPercent)

            // 刻度线
            ForEach(0..<11, id: \.self) { i in
                Rectangle()
                    .fill(amber.opacity(i % 5 == 0 ? 0.55 : 0.25))
                    .frame(width: i % 5 == 0 ? 1.5 : 1, height: i % 5 == 0 ? 6 : 3.5)
                    .offset(y: -30)
                    .rotationEffect(.degrees(150 + Double(i) * 6.67))
            }

            // 指针
            Rectangle()
                .fill(batteryColor)
                .frame(width: 2, height: 24)
                .offset(y: -12)
                .rotationEffect(.degrees(150 + 180 * batteryPercent))
                .animation(.easeOut(duration: 0.3), value: batteryPercent)

            // 中心轴
            Circle()
                .fill(amber)
                .frame(width: 5, height: 5)

            // 读数
            VStack(spacing: 0) {
                Text("\(Int(batteryPercent * 100))")
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .foregroundStyle(batteryColor)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 7))
                    .foregroundStyle(amber.opacity(0.6))
            }
            .offset(y: 15)

            // 标签
            VStack {
                Spacer()
                HStack {
                    Text("E")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(amber.opacity(0.5))
                    Spacer()
                    Text("F")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(amber.opacity(0.5))
                }
            }
            .frame(width: 70)
            .offset(y: 6)
        }
    }

    private var batteryColor: Color {
        if batteryPercent < 0.15 { return red }
        if batteryPercent < 0.30 { return themeMgr.color(.warn) }
        return themeMgr.color(.ok)
    }

    // MARK: - 底部

    private var bottomRow: some View {
        HStack(spacing: 0) {
            bottomCell("电压", String(format: "%.1f", mgr.data.voltage), "V",
                       themeMgr.color(.voltage))
            divider
            bottomCell("电流", String(format: "%.1f", mgr.data.current), "A",
                       mgr.data.isRegen ? themeMgr.color(.ok) : themeMgr.color(.current))
            divider
            bottomCell("功率", powerText, "W",
                       mgr.data.isRegen ? themeMgr.color(.ok) : amber)
            divider
            bottomCell("MOS", "\(mgr.data.mosTemp)", "°C",
                       mgr.data.mosTemp > 60 ? red : themeMgr.color(.mosTemp))
            divider
            bottomCell("电机", "\(mgr.data.motorTemp)", "°C",
                       mgr.data.motorTemp > 50 ? red : themeMgr.color(.motorTemp))
        }
        .frame(height: 42)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(amber.opacity(0.35))
                .frame(height: 1)
        }
    }

    private var powerText: String {
        let p = Int(mgr.data.power)
        return mgr.data.power < -1 ? "−\(abs(p))" : "\(p)"
    }

    private var divider: some View {
        Rectangle()
            .fill(amber.opacity(0.25))
            .frame(width: 1, height: 24)
    }

    private func bottomCell(_ title: String, _ value: String, _ unit: String,
                            _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 7, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(amber.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 8))
                    .foregroundStyle(amber.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 6)
    }
}

// MARK: - 电压 → 电量百分比

enum BatteryPercent {

    /// 按满电/没电两个阈值线性换算
    /// - Returns: 0 ~ 1
    static func compute(voltage: Double, full: Double, empty: Double) -> Double {
        guard full > empty, voltage > 0 else { return 0 }
        let p = (voltage - empty) / (full - empty)
        return min(max(p, 0), 1)
    }
}
