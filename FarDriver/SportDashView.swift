//
//  SportDashView.swift
//  竞技风格横屏仪表（EVA 诊断屏风格）
//
//  - 纯黑底（或自定义图片）+ 琥珀色单色线框
//  - 转速按用户设置的倍率放大显示（原厂 100rpm → 1000rpm）
//  - 右下角指针式电量表，按电压阈值算百分比
//  - 没连控制器时进自检模式：故障灯全亮呼吸闪烁
//

import SwiftUI
import Combine

struct SportDashView: View {
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager
    @ObservedObject var gps: GpsSpeed
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var bms = AntBmsManager.shared
    @ObservedObject var trip = TripMeter.shared

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
    ///
    /// 没连控制器时电压是 0，表针强制归零（指向 E）。
    private var batteryPercent: Double {
        guard mgr.status.isConnected else { return 0 }
        return BatteryPercent.compute(voltage: mgr.data.voltage,
                                      full: theme.battFullVoltage,
                                      empty: theme.battEmptyVoltage)
    }

    private var amber: Color { themeMgr.color(.power) }
    private var cyan: Color { themeMgr.color(.rpm) }
    private var red: Color { themeMgr.color(.warn) }

    /// 故障灯的黄色（固定色，不受主题色影响，和真车指示灯一致）
    private var lampYellow: Color { Color(hex: "#FFC107") }
    /// 电瓶灯用的橙黄（和参考图标一致）
    private var lampAmber: Color { Color(hex: "#FB9B08") }

    // MARK: - 故障灯状态

    /// 自检模式：还没连上控制器时，所有灯全亮
    ///
    /// 这是老车/新车的自检行为——点火瞬间所有灯亮一遍，确认灯本身没坏。
    /// 连上控制器后立刻切到正常模式，按真实数据决定谁亮。
    private var inSelfTest: Bool { !mgr.status.isConnected }

    /// 电瓶故障灯：电量低于 26%
    private var batteryLampOn: Bool {
        if inSelfTest { return true }
        return batteryPercent < 0.26
    }

    /// 水温故障灯：MOS 温度高于 50°C
    private var coolantLampOn: Bool {
        if inSelfTest { return true }
        return mgr.data.mosTemp > 50
    }

    /// 发动机故障灯：控制器 MOS 温度到达 60°C
    private var engineLampOn: Bool {
        if inSelfTest { return true }
        return mgr.data.mosTemp >= 60
    }

    /// 刹车灯：直接读控制器上报的刹车信号（0xE2 的 p[3] bit7）
    ///
    /// 实测：捏刹车 p[3] = 0x80，松开 p[3] = 0x00。
    /// 不再靠「掉速」推断，按住刹车不走也能亮。
    private var brakeLampOn: Bool {
        if inSelfTest { return true }
        guard mgr.status.isConnected, mgr.data.e2Seen else { return false }
        return mgr.data.braking
    }

    /// 自检闪烁相位
    @State private var pulsePhase: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            topBar
            rpmBand
            middleRow
            bottomRow
            debugPinRow
        }
        .padding(10)
        .background(sportBackground)
        .onAppear {
            weather.refreshIfNeeded()
        }
        // 自检模式下让灯呼吸闪，用时间线驱动
        .onReceive(Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()) { _ in
            tickPulse()
        }
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
                        // 连上控制器后显示「正常」，没连上显示「自检中」
                        if inSelfTest {
                            Text("自检中")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(themeMgr.color(.power))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .opacity(pulseOpacity)
                        } else {
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

            // 日期 + 时间（上下两行）
            clockBlock

            Spacer(minLength: 6)

            // 天气图标 + 气温
            weatherBlock

            Spacer(minLength: 6)

            // 故障灯：自检时全亮呼吸闪烁，连上后按真实状态
            HStack(spacing: 5) {
                brakeLamp    // 刹车（红）
                engineLamp   // 发动机（黄，MOS ≥ 60°C）
                coolantLamp  // 水温（黄，MOS > 50°C）
                batteryLamp  // 电瓶（黄，电量 < 26%）
            }
            .opacity(inSelfTest ? pulseOpacity : 1.0)

            Spacer(minLength: 4)

            dashPill("DIAGNOSTIC", on: !inSelfTest)
            dashPill("SETTINGS", on: true)
        }
        .frame(height: 30)
    }

    /// 自检模式的呼吸闪烁透明度
    private var pulseOpacity: Double {
        guard inSelfTest else { return 1.0 }
        return 0.45 + 0.55 * (0.5 + 0.5 * sin(pulsePhase))
    }

    /// 每帧更新相位（自检模式下指示灯呼吸）
    private func tickPulse() {
        guard inSelfTest else { return }
        pulsePhase += 0.18
    }

    // MARK: - 日期时间

    /// 上方时间块：第一行「10月29日」，第二行「21:24」
    private var clockBlock: some View {
        VStack(alignment: .center, spacing: -1) {
            Text(dateText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(amber.opacity(0.65))
                .monospacedDigit()
            Text(timeText)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(amber)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    /// 「10月29日」+ 星期
    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f.string(from: Date())
    }

    // MARK: - 天气块

    @ViewBuilder
    private var weatherBlock: some View {
        if let t = weather.temperature {
            HStack(spacing: 5) {
                Image(systemName: weather.symbolName)
                    .font(.system(size: 16))
                    .foregroundStyle(amber)
                VStack(alignment: .leading, spacing: -1) {
                    Text("\(Int(t.rounded()))°")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(amber)
                        .monospacedDigit()
                    if !weather.conditionText.isEmpty {
                        Text(weather.conditionText)
                            .font(.system(size: 7))
                            .foregroundStyle(amber.opacity(0.55))
                    }
                }
            }
        }
    }

    // MARK: - 故障灯
    //
    // 自检模式灯全亮，正常模式灯灭/亮看真实数据。

    /// 红色刹车启动灯（圆圈 + 感叹号）
    private var brakeLamp: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 15))
            .foregroundStyle(brakeLampOn ? red : red.opacity(0.16))
            .shadow(color: brakeLampOn ? red.opacity(0.9) : .clear, radius: 4)
    }

    /// 黄色水温故障灯（温度计插在水里）
    private var coolantLamp: some View {
        Image(systemName: "thermometer.medium")
            .font(.system(size: 14))
            .foregroundStyle(coolantLampOn ? lampYellow : amber.opacity(0.16))
            .shadow(color: coolantLampOn ? lampYellow.opacity(0.9) : .clear, radius: 4)
    }

    /// 黄色发动机故障灯（发动机轮廓）
    private var engineLamp: some View {
        Image(systemName: "engine.combustion")
            .font(.system(size: 14))
            .foregroundStyle(engineLampOn ? lampYellow : amber.opacity(0.16))
            .shadow(color: engineLampOn ? lampYellow.opacity(0.9) : .clear, radius: 4)
    }

    /// 黄色电瓶故障灯（汽车小电瓶造型，自己画的）
    private var batteryLamp: some View {
        CarBatteryIcon(color: batteryLampOn ? lampAmber : lampAmber.opacity(0.16))
            .frame(width: 18, height: 14)
            .shadow(color: batteryLampOn ? lampAmber.opacity(0.9) : .clear, radius: 4)
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
            // 左侧：控制器连接指示灯
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

            // 右侧：BMS 温度 + 油表
            // BMS 块靠近档位一侧，油表占最右边，给足空间
            HStack(alignment: .center, spacing: 10) {
                if showBmsBlock {
                    bmsMosTempBlock
                        .offset(x: -6)
                }
                fuelGauge
                    .frame(width: 72, height: 116)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// BMS 温度块什么时候显示
    ///
    /// - 自检阶段（还没连控制器）：亮起，显示 `--`
    /// - 连上控制器但没连 ANT BMS：隐藏
    /// - 连上 ANT BMS：亮起，显示真实温度
    private var showBmsBlock: Bool {
        if !mgr.status.isConnected { return true }   // 自检
        return bms.connected
    }

    /// P 档：直接读控制器上报的状态（0xE2 的 p[0] bit0）
    ///
    /// 实测：挂入 P 时 p[0] = 0x80，解除时 p[0] = 0x81。
    /// 不再靠「速度 + 电流」猜，滑行和坡道溜车都不会再误判。
    private var isParked: Bool {
        guard mgr.status.isConnected, mgr.data.e2Seen else { return false }
        return mgr.data.pGearOn
    }

    // MARK: - BMS 保护板 MOS 温度

    /// 油表左边的小方块：BMS 保护板 MOS 温度
    private var bmsMosTempBlock: some View {
        let t = bms.data.mosTemp
        let hot = t > 55
        let known = bms.connected && t > 0
        return VStack(spacing: 1) {
            Text("BMS")
                .font(.system(size: 6, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(amber.opacity(0.55))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(known ? "\(t)" : "--")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(hot ? red : cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("°")
                    .font(.system(size: 7))
                    .foregroundStyle(amber.opacity(0.55))
            }
            Text("MOS")
                .font(.system(size: 6, weight: .medium))
                .foregroundStyle(amber.opacity(0.45))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(amber.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(hot ? red.opacity(0.7) : amber.opacity(0.28), lineWidth: 1)
        }
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
    //
    // 严格按参考图重画：
    //   - 竖向半圆，弧在右边，开口朝左
    //   - 圆心在左侧偏下，指针从圆心向右上方伸出
    //   - F 在弧顶端内侧，E 在弧底端内侧
    //   - 刻度：F 旁一根长、中间两根短、E 旁一根长，全部在弧内侧
    //   - 红色宽指针，根部粗、尖端细，指针头接近弧

    /// 加油灯的显隐：低于 30%
    ///
    /// 没连控制器时表针归零，但这不代表真的没油，所以加油灯跟着自检逻辑走。
    private var fuelLampOn: Bool {
        if inSelfTest { return true }
        return batteryPercent < 0.30
    }

    private var fuelGauge: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                drawFuelGauge(ctx: &ctx, size: size)
            }
            .frame(width: 72, height: 116)

            // 加油灯：左上角（和参考图一致）
            fuelWarningLamp
        }
        .frame(width: 72, height: 116, alignment: .topLeading)
    }

    /// 画扇形油表（参考图布局）
    ///
    /// 尺寸固化，不依赖父容器给的尺寸，避免被压扁或裁掉上半截。
    /// 整块画在 72 × 116 里：
    ///   弧顶 y≈19，弧底 y≈93，F/E 字在 8~108 之间，全部在框内。
    private func drawFuelGauge(ctx: inout GraphicsContext, size: CGSize) {
        // 圆心固定在左侧，垂直居中
        let cx: CGFloat = 8
        let cy: CGFloat = 58
        // 半径：让弧上下都留出标签空间
        let r: CGFloat = 46

        // t=0 → F（-55°，右上方），t=1 → E（+55°，右下方），扫角 110°
        let startDeg: Double = -55
        let sweepDeg: Double = 110
        func point(at t: Double, radius: Double) -> CGPoint {
            let deg = startDeg + sweepDeg * t
            let rad = deg * Double.pi / 180
            return CGPoint(x: cx + CGFloat(cos(rad)) * radius,
                           y: cy + CGFloat(sin(rad)) * radius)
        }

        // ① 弧：单一线宽，粗细均匀（参考图就是均一的细弧）
        let steps = 70
        var arc = Path()
        arc.move(to: point(at: 0, radius: r))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            arc.addLine(to: point(at: t, radius: r))
        }
        ctx.stroke(arc, with: .color(amber),
                   style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

        // ② 已用电量弧：贴在弧内侧，表示当前还剩多少
        if batteryPercent > 0.001 {
            var used = Path()
            // 从 F 端（t=0）往 E 方向画到当前电量
            let usedSteps = max(2, Int(Double(steps) * (1 - batteryPercent)))
            for i in 0...usedSteps {
                let t = (1 - batteryPercent) * Double(i) / Double(usedSteps)
                let p = point(at: t, radius: r - 3.5)
                if i == 0 { used.move(to: p) } else { used.addLine(to: p) }
            }
            ctx.stroke(used, with: .color(batteryColor.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }

        // ③ 刻度：全部在弧内侧，朝圆心方向伸
        let tickTs: [(t: Double, len: CGFloat, width: CGFloat)] = [
            (0.06, 9, 2.4),    // F 旁长刻度
            (0.38, 5.5, 2.0),  // 中上短刻度
            (0.62, 5.5, 2.0),  // 中下短刻度
            (0.94, 9, 2.4),    // E 旁长刻度
        ]
        for tick in tickTs {
            let p1 = point(at: tick.t, radius: r - 2.5)
            let p2 = point(at: tick.t, radius: r - 2.5 - Double(tick.len))
            var tp = Path()
            tp.move(to: p1)
            tp.addLine(to: p2)
            ctx.stroke(tp, with: .color(amber),
                       style: StrokeStyle(lineWidth: tick.width, lineCap: .round))
        }

        // ④ F / E 标签：放到弧外侧，彻底避开指针
        let fPos = point(at: 0.00, radius: r + 10)
        let ePos = point(at: 1.00, radius: r + 10)
        ctx.draw(
            Text("F").font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(amber),
            at: fPos
        )
        ctx.draw(
            Text("E").font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(amber),
            at: ePos
        )

        // ⑤ 红色宽指针：从圆心指向当前电量
        //
        // 指针末端限制在长刻度内侧，保证 0% / 100% 都不越过刻度线。
        let tickOuter = r - 2.5          // 刻度起点（贴弧）
        let longTickLen: CGFloat = 9
        let needleLen = tickOuter - longTickLen + 3

        // 角度收 3°，避免压到两端的长刻度
        let angleStart = startDeg + 3
        let angleSweep = sweepDeg - 6
        let angleDeg = angleStart + angleSweep * (1 - batteryPercent)
        let rad = angleDeg * Double.pi / 180

        let tip = CGPoint(x: cx + CGFloat(cos(rad)) * needleLen,
                          y: cy + CGFloat(sin(rad)) * needleLen)
        // 根部：从圆心开始，粗
        let rootLen = needleLen * 0.42
        let rootEnd = CGPoint(x: cx + CGFloat(cos(rad)) * rootLen,
                              y: cy + CGFloat(sin(rad)) * rootLen)
        var rootPath = Path()
        rootPath.move(to: CGPoint(x: cx, y: cy))
        rootPath.addLine(to: rootEnd)
        ctx.stroke(rootPath, with: .color(red),
                   style: StrokeStyle(lineWidth: 6, lineCap: .round))

        // 尖端：续接，细
        var tipPath = Path()
        tipPath.move(to: rootEnd)
        tipPath.addLine(to: tip)
        ctx.stroke(tipPath, with: .color(red),
                   style: StrokeStyle(lineWidth: 2.8, lineCap: .round))

        // ⑥ 圆心小点
        let hub = CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4)
        ctx.fill(Circle().path(in: hub), with: .color(red))
    }

    /// 加油灯：油泵造型
    private var fuelWarningLamp: some View {
        Image(systemName: "fuelpump.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(fuelLampOn ? lampAmber : amber.opacity(0.16))
            .shadow(color: fuelLampOn ? lampAmber.opacity(0.9) : .clear, radius: 4)
            .opacity(inSelfTest ? pulseOpacity : 1)
    }

    private var batteryColor: Color {
        if batteryPercent < 0.15 { return red }
        if batteryPercent < 0.30 { return lampAmber }
        return amber
    }

    // MARK: - 调试：P 档嗅探
    //
    // 用来在实车上找 P 档的信号位。
    // 把 0xE2 和 0xEE 两帧的原始字节显示出来，按 P 键前后对比就能定位。
    // 找到之后这行可以删掉。

    private var debugPinRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("E2")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber.opacity(0.5))
                Text(mgr.data.e2Raw.isEmpty ? "—" : mgr.data.e2Raw)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(amber.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            HStack(spacing: 6) {
                Text("EE")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber.opacity(0.5))
                Text(mgr.data.eeRaw.isEmpty ? "—" : mgr.data.eeRaw)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(amber.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("pin=\(mgr.data.eePinType) bit=\(mgr.data.eePinBit)")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(cyan)
            }
            // 速度来源诊断：R=轮径 W=轮宽 ratio=比例 rate=分母 measure=原始
            HStack(spacing: 6) {
                Text("SPD")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber.opacity(0.5))
                Text(mgr.data.d0Seen
                     ? String(format: "R%d W%d r%d rate%d meas%d avg%.0f",
                              mgr.data.wheelRadius, mgr.data.wheelWidth,
                              mgr.data.wheelRatio, mgr.data.rateRatio,
                              mgr.data.measureSpeed, mgr.data.controllerSpeedKmh)
                     : "D0 未收到")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(amber.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
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
            divider
            // 小计里程 / 百公里电耗 / 平均功率
            bottomCell("小计", trip.distanceText, "km", cyan)
            divider
            bottomCell("百公里", trip.consumptionText, "kWh", amber)
            divider
            bottomCell("平均", trip.avgPowerText, "W", themeMgr.color(.motorTemp))
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
