//
//  SportDashView.swift
//  竞技风格横屏仪表（EVA 诊断屏风格）
//
//  设计要点：
//  - 纯黑底 + 琥珀色单色，所有笔画都是细线
//  - 右下角斜切「天使环」装饰，纯 SwiftUI 画的，不用图片
//  - 转速用长条刻度（20 格），每格 200rpm，超过红区变红
//  - 数字用等宽数字字体，不用 rounded，更有仪器感
//  - 颜色可以从主题里取，背景单独有「竞技底色」设置
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

    /// 转速百分比（满量程 12000rpm）
    private var rpmRatio: Double {
        min(max(mgr.data.rpm / 12000.0, 0), 1)
    }

    /// 主色：琥珀
    private var amber: Color { themeMgr.color(.power) }
    /// 强调色：青
    private var cyan: Color { themeMgr.color(.rpm) }
    /// 警告色
    private var red: Color { themeMgr.color(.warn) }

    var body: some View {
        VStack(spacing: 6) {
            topBar
            rpmBand
            middleRow
            bottomRow
        }
        .padding(10)
    }

    // MARK: - 顶部：标题 + 时钟 + 两颗按钮

    private var topBar: some View {
        HStack(spacing: 8) {
            // 左：标志 + 标题（两层字，模仿原图的「車雨状態診断 / VEHICLE DIAGNOSTIC」）
            HStack(spacing: 6) {
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(red)
                VStack(alignment: .leading, spacing: 0) {
                    Text("车辆状态诊断")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(amber)
                    Text("VEHICLE DIAGNOSTIC")
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(amber.opacity(0.55))
                }
            }

            Spacer(minLength: 6)

            // 中：时间
            Text(nowText())
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(amber)
                .padding(.horizontal, 6)

            Spacer(minLength: 6)

            // 右：两粒状态药丸
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
            // 大号转速数字
            VStack(alignment: .leading, spacing: -2) {
                Text("ENGINE  RPM / 转速")
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(amber.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(mgr.data.rpm.rounded()))")
                        .font(.system(size: 30, weight: .heavy, design: .monospaced))
                        .foregroundStyle(amber)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("rpm")
                        .font(.system(size: 9))
                        .foregroundStyle(amber.opacity(0.6))
                }
            }
            .frame(width: 130, alignment: .leading)

            // 刻度条：20 格，每格 200rpm
            VStack(spacing: 2) {
                // 上排细刻度（装饰）
                HStack(spacing: 1.5) {
                    ForEach(0..<40, id: \.self) { i in
                        Rectangle()
                            .fill(amber.opacity(0.25))
                            .frame(width: 2, height: i % 2 == 0 ? 5 : 3)
                    }
                }
                // 主进度条
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(amber.opacity(0.12))
                        // 红区
                        Rectangle()
                            .fill(red.opacity(0.22))
                            .frame(width: g.size.width * 0.25)
                            .offset(x: g.size.width * 0.75)
                        // 当前转速
                        Rectangle()
                            .fill(rpmRatio > 0.85 ? red : amber)
                            .frame(width: max(0, g.size.width * rpmRatio))
                        // 缺口分段
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

                // 下排刻度数字
                HStack(spacing: 0) {
                    ForEach([0, 2000, 4000, 6000, 8000, 10000, 12000], id: \.self) { n in
                        Text("\(n)")
                            .font(.system(size: 6, weight: .medium, design: .monospaced))
                            .foregroundStyle(amber.opacity(0.5))
                        if n != 12000 { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .frame(height: 50)
    }

    // MARK: - 中间：速度 + 装饰

    private var middleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // 左：小绿灯（原图的绿色指示点）
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

            // 中间：速度大数字
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(Int(speed.rounded()))")
                    .font(.system(size: 74, weight: .heavy, design: .monospaced))
                    .foregroundStyle(amber)
                    .monospacedDigit()
                    .lineLimit(1)
                    .shadow(color: amber.opacity(0.55), radius: 10)
                Text("km/h")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(amber.opacity(0.75))
            }
            .padding(.leading, 2)

            Spacer(minLength: 0)

            // 右：P 档 + 档位
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
            // 天使环装饰：右下角斜切的几个同心弧，纯装饰
            .overlay(alignment: .bottomTrailing) {
                angelRing
                    .offset(x: 62, y: 30)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// P 档判定：已连接 + 没速度 + 没电流
    private var isParked: Bool {
        guard mgr.status.isConnected else { return false }
        return speed < 1.0 && abs(mgr.data.current) < 0.5
    }

    /// 天使环：几道同心弧，斜切在右下角
    private var angelRing: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .trim(from: 0.55, to: 0.95)
                    .stroke(
                        red.opacity(0.35 - Double(i) * 0.07),
                        style: StrokeStyle(lineWidth: i == 0 ? 2.5 : 1.2, lineCap: .round)
                    )
                    .frame(width: 60 + CGFloat(i) * 14, height: 60 + CGFloat(i) * 14)
            }
        }
        .frame(width: 110, height: 110)
    }

    // MARK: - 底部：电压电流温度功率

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
