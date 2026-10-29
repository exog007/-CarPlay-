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

    /// 刹车灯：松开灭
    ///
    /// ⚠️ 控制器协议里还没解出确定的刹车灯信号位，现在是推断：
    ///   - 车在走（速度 > 3）时按下刹车，速度会明显下降
    ///   - 单帧掉 2.5 km/h 以上认为在刹车
    ///   - 一旦不再掉速（松开刹车 / 重新加速）立刻灭
    /// 想要精确的刹车灯，需要抓一帧「捏着刹车」的原始数据来对位偏移。
    private var brakeLampOn: Bool {
        if inSelfTest { return true }
        return brakeActive
    }

    @State private var lastSpeed: Double = 0
    @State private var brakeActive = false
    /// 自检闪烁相位
    @State private var pulsePhase: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            topBar
            rpmBand
            middleRow
            bottomRow
        }
        .padding(10)
        .background(sportBackground)
        .onChange(of: mgr.data.speed) { _, newValue in
            updateBrake(newValue)
        }
        .onAppear {
            weather.refreshIfNeeded()
        }
        // 自检模式下让灯呼吸闪，用时间线驱动
        .onReceive(Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()) { _ in
            tickPulse()
        }
    }

    /// 每来一帧新速度就重新判断刹车
    private func updateBrake(_ newSpeed: Double) {
        let prev = lastSpeed
        lastSpeed = newSpeed

        guard mgr.status.isConnected else {
            brakeActive = false
            return
        }

        // 减速量（正值表示掉速）
        let decel = prev - newSpeed

        // 速度太低不考虑刹车（已经停下）
        guard newSpeed >= 1 else {
            brakeActive = false
            return
        }

        // 掉速超过 2.5 km/h 点亮；保持不变或加速就灭
        if decel > 2.5 {
            brakeActive = true
        } else if decel <= 0.5 {
            brakeActive = false
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
            HStack(spacing: 6) {
                if showBmsBlock {
                    bmsMosTempBlock
                }
                fuelGauge
                    .frame(width: 78, height: 78)
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

    private var isParked: Bool {
        guard mgr.status.isConnected else { return false }
        return speed < 1.0 && abs(mgr.data.current) < 0.5
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
    // 造型按参考图：
    //   - 左粗右细的弧形轨道，开口朝左
    //   - 极简刻度：F 上方一根长刻度，中间两根短刻度，E 下方一根长刻度
    //   - 红色宽指针，根部粗、尖端细，超出轨道一点
    //   - 电量低于 30% 时左上角亮起加油灯

    /// 轨道起始角：E 在下方，F 在上方。
    /// SwiftUI 的 0° 指向右侧，顺时针为正。
    /// F 用 -50°（右上方），E 用 130°（左下方），总共 180°。
    private let gaugeStart: Double = 130    // E
    private let gaugeSweep: Double = 180    // 到 F

    /// 指针角度：0% → E(130°)，100% → F(-50°=310°)
    private var needleAngle: Double {
        gaugeStart - gaugeSweep * batteryPercent
    }

    /// 加油灯：低于 30%
    private var fuelLampOn: Bool {
        if inSelfTest { return true }
        return batteryPercent < 0.30
    }

    private var fuelGauge: some View {
        ZStack {
            // ① 轨道：左粗右细
            GaugeTrack(start: gaugeStart, sweep: gaugeSweep)
                .stroke(amber, lineWidth: 3)
                .mask(
                    // 用渐变控制粗细：靠近 E 一端粗，靠近 F 一端细
                    GaugeTrack(start: gaugeStart, sweep: gaugeSweep)
                        .stroke(
                            LinearGradient(
                                colors: [.black, .black.opacity(0.55)],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                )

            // ② 已用油量：从 E 到当前的电量弧（细一号，压在轨道上）
            GaugeTrack(start: gaugeStart, sweep: gaugeSweep * batteryPercent)
                .stroke(batteryColor.opacity(0.35), lineWidth: 2)

            // ③ 刻度
            ForEach(gaugeTicks, id: \.angle) { tick in
                Capsule()
                    .fill(amber)
                    .frame(width: tick.w, height: tick.len)
                    .offset(y: -24)
                    .rotationEffect(.degrees(tick.angle))
            }

            // ④ 红色宽指针（根部粗、尖端细）
            Capsule()
                .fill(
                    LinearGradient(colors: [red.opacity(0.85), red],
                                   startPoint: .bottom,
                                   endPoint: .top)
                )
                .frame(width: 5, height: 30)
                .offset(y: -13)
                .rotationEffect(.degrees(needleAngle))
                .animation(.easeOut(duration: 0.35), value: batteryPercent)

            // ⑤ 中心轴
            Circle()
                .fill(amber)
                .frame(width: 4, height: 4)

            // ⑥ F / E 标签
            Text("F")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(amber)
                .offset(x: -26, y: -26)
            Text("E")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(amber)
                .offset(x: -34, y: 26)

            // ⑦ 加油灯（左上角）
            fuelWarningLamp
                .offset(x: -40, y: -40)
        }
        .frame(width: 78, height: 78)
    }

    /// 加油灯：油泵造型
    private var fuelWarningLamp: some View {
        Image(systemName: "fuelpump")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(fuelLampOn ? lampAmber : amber.opacity(0.16))
            .shadow(color: fuelLampOn ? lampAmber.opacity(0.9) : .clear, radius: 4)
            .opacity(inSelfTest ? pulseOpacity : 1)
    }

    /// 刻度定义：F 处一根长、中间两根短、E 处一根长
    private var gaugeTicks: [(angle: Double, len: CGFloat, w: CGFloat)] {
        // 从 E 算角度：F 在上方、E 在下方
        let fAngle = gaugeStart - gaugeSweep          // -50°
        let eAngle = gaugeStart                        // 130°
        return [
            (fAngle, 14, 2.5),                         // F 长刻度
            (fAngle + 60, 8, 2),                       // 中间短
            (fAngle + 120, 8, 2),                      // 中间短
            (eAngle, 14, 2.5),                         // E 长刻度
        ]
    }

    private var batteryColor: Color {
        if batteryPercent < 0.15 { return red }
        if batteryPercent < 0.30 { return lampAmber }
        return amber
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

// MARK: - 弧形轨道

/// 按角度范围画一段圆弧
///
/// SwiftUI 的 `Circle().trim()` 只能从 0° 开始，画不了「任意起点 + 任意角度」，
/// 所以自己算路径。
struct GaugeTrack: Shape {
    /// 起始角（度），0° 指向右，正数顺时针
    var start: Double
    /// 扫过角度（度），正数顺时针，负数逆时针
    var sweep: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        guard r > 0, abs(sweep) > 0.01 else { return p }

        // 用逐点采样画，避开 addArc 的 clockwise 参数语义坑
        let steps = max(2, Int(abs(sweep) / 2))
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let deg = start + sweep * t
            let rad = deg * Double.pi / 180
            let pt = CGPoint(x: c.x + CGFloat(cos(rad)) * r,
                             y: c.y + CGFloat(sin(rad)) * r)
            if i == 0 {
                p.move(to: pt)
            } else {
                p.addLine(to: pt)
            }
        }
        return p
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
