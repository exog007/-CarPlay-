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

// MARK: - 通知（竞技仪表顶部悬浮按钮用）

extension Notification.Name {
    /// 退出竞技仪表、切回竖屏标准界面
    static let sportExitToPortrait = Notification.Name("sportExitToPortrait")
    /// 从竞技仪表打开设置
    static let sportOpenSettings = Notification.Name("sportOpenSettings")
}

struct SportDashView: View {
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager
    @ObservedObject var gps: GpsSpeed
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var bms = AntBmsManager.shared
    @ObservedObject var trip = TripMeter.shared
    @ObservedObject var rpmStore = RpmDisplayStore.shared

    /// 转速平滑器（独立 ObservableObject，避免整个仪表重绘）
    ///
    /// 之前 smoothRpm 是 @State，每帧变化会让整个 SportDashView.body 重绘，
    /// body 里有几十个视图，60Hz 下就会掉帧、看起来一顿一顿。
    /// 现在拆成独立对象，只有引用它的那几个视图会刷新。
    @StateObject private var rpmSmoother = RpmSmoother()

    /// 便捷读取当前平滑值
    private var smoothRpm: Double { rpmSmoother.value }

    /// 平滑定时器（挂在 smoother 上）
    private var rpmSmoothTimer: Timer? {
        get { rpmSmoother.timer }
        nonmutating set { rpmSmoother.timer = newValue }
    }

    /// 行程统计喂数据用的定时器（GPS 模式）
    @State private var tripFeedTimer: Timer?
    /// OBD2 数据（汽车/摩托模式）
    @ObservedObject var obd = ObdManager.shared
    /// 报警阈值：改完设置立刻反映到故障灯
    @AppStorage(AlarmThreshold.coolantHighKey) private var coolantHigh: Double = 105
    @AppStorage(AlarmThreshold.batteryLowKey) private var batteryLow: Double = 11.8
    /// 当前数据源（跟 @AppStorage 同步，切换后主题立刻换）
    @AppStorage("dataSource") private var dataSource: DataSource = .fardriver
    /// 主题存储：改颜色/背景后触发重绘
    @ObservedObject private var themeStore = DashThemeStore.shared
    /// 档位显示方式：设置里改完立刻生效
    @AppStorage("gearDisplayMode") private var gearDisplayMode: GearDisplayMode = .auto
    /// 变速箱类型（自动挡 / 手动挡）：决定档位框长什么样
    @AppStorage("gearboxMode") private var gearboxMode: GearboxMode = .auto
    /// 是否显示百公里油耗（只对 OBD 有效）
    ///
    /// 很多车不上报 PID 5E（燃油消耗率），这时这一格永远是 "—"，
    /// 与其占地方不如让用户关掉。
    @AppStorage("dashShowFuelConsumption") private var showFuelConsumption: Bool = true

    /// 是否显示档位框
    ///
    /// 大多数车读不到真实档位（PID A4 不支持），档位框会一直停在同一个值，
    /// 与其占地方不如留个开关关掉。
    @AppStorage("dashShowGear") private var showGear: Bool = true
    /// OBD2 模式是否显示右侧油表
    @AppStorage("obdShowFuelGauge") private var obdShowFuelGaugePref: Bool = true

    /// OBD2 油表实际是否显示
    ///
    /// 两个条件都满足才显示：
    ///   ① 设置里开了开关
    ///   ② 真的读到了燃油液位数据（避免没数据时指针乱晃或一直空表）
    private var showObdFuelGauge: Bool {
        guard obdShowFuelGaugePref else { return false }
        guard let pct = obd.reading.fuelLevel else { return false }
        return pct >= 0 && pct <= 105
    }
    /// 布局微调（XY 独立缩放 + 位移）
    @ObservedObject private var layoutStore = DashLayoutStore.shared

    // MARK: - 数据源

    /// 当前是不是 OBD2 模式
    ///
    /// OBD2 模式下：
    ///   · 转速来自发动机 ECU（不是电机）
    ///   · 车速优先用 OBD2 的，没有则用 GPS
    ///   · 隐藏电机温度、BMS、档位等电动车专属区块
    ///   · 用「燃油表」代替「电量表」
    private var isObd: Bool { dataSource.isObdFamily }

    /// 是否已经拿到数据（决定故障灯自检还是正常）
    private var sourceConnected: Bool {
        isObd ? obd.status.isConnected : mgr.status.isConnected
    }

    /// 融合车速
    ///
    ///   · 远驱：控制器转速换算（远驱没得选）
    ///   · OBD 三个数据源：按设置里的「速度来源」走
    ///       OBD → PID 010D
    ///       GPS → 手机定位（刷新快、精度高）
    private var speed: Double {
        if isObd {
            // 摩托车固定用 GPS：OBD 那边已经不轮询 010D 了
            if dataSource == .motorcycle {
                return gps.smoothSpeed
            }
            switch SpeedSource.current {
            case .gps:
                // GPS：有定位就用它，没定位就退回 OBD
                if gps.hasFix {
                    return gps.smoothSpeed
                }
                return obd.reading.speedKmh ?? 0
            case .obd:
                // OBD：优先 ECU 值，ECU 不给就用 GPS 兜底
                if let s = obd.reading.speedKmh { return s }
                return gps.smoothSpeed
            }
        }
        return gps.fused(with: mgr.data.speed)
    }

    private var theme: AppTheme { themeMgr.theme }

    /// 放大后的转速
    ///
    /// 三种数据源都应用「转速倍率」，这样：
    ///   · 远驱：原厂报 100 → 显示 1000（×10）
    ///   · OBD：真实 800 → 也能按需放大或缩小
    /// 倍率在「设置 → 个性化 → 转速倍率」里调，1 就是原始值。
    private var displayRpm: Double {
        let raw: Double = isObd ? (obd.reading.rpm ?? 0) : mgr.data.rpm
        return raw * rpmStore.current.multiplier
    }

    /// 转速百分比（自检动画期间跟着动画走）
    private var rpmRatio: Double {
        let maxRpm = rpmStore.current.scaleMax
        guard maxRpm > 0 else { return 0 }
        return min(max(displayRpmValue / maxRpm, 0), 1)
    }

    /// 电量百分比（按电压阈值线性插值）
    ///
    /// OBD2 模式改用「燃油液位」；远驱模式仍是电池电压换算。
    /// 没连上时表针强制归零（指向 E）。
    private var batteryPercent: Double {
        if isObd {
            guard obd.status.isConnected, let pct = obd.reading.fuelLevel else { return 0 }
            return min(max(pct / 100.0, 0), 1)
        }
        guard mgr.status.isConnected else { return 0 }
        return BatteryPercent.compute(voltage: mgr.data.voltage,
                                      full: theme.battFullVoltage,
                                      empty: theme.battEmptyVoltage)
    }

    /// 强调色：跟随当前数据源的独立主题
    ///
    /// 电动车默认琥珀，OBD2 默认青蓝，各自可以在设置里单独改。
    private var amber: Color { dashTheme.accentColor }
    /// 转速/次要色
    private var cyan: Color { dashTheme.rpmColor }
    /// 警告红
    private var red: Color { dashTheme.warnColor }

    /// 故障灯的黄色（固定色，不受主题色影响，和真车指示灯一致）
    private var lampYellow: Color { Color(hex: "#FFC107") }
    /// 电瓶灯用的橙黄（和参考图标一致）
    private var lampAmber: Color { Color(hex: "#FB9B08") }

    // MARK: - 故障灯状态

    /// 自检模式：还没连上数据源，或者开机自检动画还在播放时，所有灯全亮
    ///
    /// 这是老车/新车的自检行为——点火瞬间所有灯亮一遍，确认灯本身没坏。
    /// 连上后立刻切到正常模式，按真实数据决定谁亮。
    private var inSelfTest: Bool {
        !sourceConnected || bootAnimating
    }

    /// 电瓶故障灯：远驱模式看电量；OBD2 模式看电瓶电压低于设定阈值
    private var batteryLampOn: Bool {
        if inSelfTest { return true }
        if isObd {
            guard let v = obd.reading.batteryVoltage else { return false }
            return v < batteryLow
        }
        return batteryPercent < 0.26
    }

    /// 水温故障灯
    ///
    /// 远驱模式：MOS 温度高于 50°C
    /// OBD2 模式：发动机水温高于设定阈值（默认 105°C）
    private var coolantLampOn: Bool {
        if inSelfTest { return true }
        if isObd {
            guard let t = obd.reading.coolantTemp else { return false }
            return t > coolantHigh
        }
        return mgr.data.mosTemp > 50
    }

    /// 发动机故障灯
    ///
    /// 远驱模式：控制器 MOS 温度到达 60°C
    /// OBD2 模式：读到故障码就亮（这才是真正的「检查发动机」灯）
    private var engineLampOn: Bool {
        if inSelfTest { return true }
        if isObd {
            return !obd.dtcCodes.isEmpty
        }
        return mgr.data.mosTemp >= 60
    }

    /// 刹车灯
    ///
    /// 远驱模式：直接读控制器上报的刹车信号（0xE2 的 p[3] bit7）
    /// OBD2 模式：标准 PID 没有刹车信号，用「速度明显下降」粗略推断
    private var brakeLampOn: Bool {
        if inSelfTest { return true }
        if isObd {
            return obd.reading.speedKmh == 0 && obd.reading.rpm != nil && (obd.reading.rpm ?? 0) > 600
        }
        guard mgr.status.isConnected, mgr.data.e2Seen else { return false }
        return mgr.data.braking
    }

    /// 自检闪烁相位
    @State private var pulsePhase: Double = 0

    // MARK: - 开机自检动画
    //
    // 进入竞技仪表时播放一次：
    //   速度从 0 扫到 299 再回 0
    //   转速从 0 扫到满量程再回 0
    //   期间所有故障灯全亮（就是自检状态）
    /// 自检动画进行中
    @State private var bootAnimating = false
    /// 自检动画进度 0 → 1 → 0
    @State private var bootProgress: Double = 0
    /// 自检动画计时器
    @State private var bootTimer: Timer?

    /// 自检时速度表的最大值
    private let bootSpeedMax: Double = 299
    /// 整个自检动画时长（秒）
    private let bootDuration: Double = 2.4

    var body: some View {
        // 用 GeometryReader 拿到真实尺寸，等屏幕彻底转好（宽稳定大于高）再放动画，
        // 否则旋转过程中就开始扫表，会看到动画被裁一半或者时间轴对不上。
        GeometryReader { geo in
            let ready = geo.size.width > geo.size.height + 1

            // 只给灵动岛/底部横条留位置，左右贴边铺满
            let insets = geo.safeAreaInsets
            let padTop = insets.top + 2
            let padBottom = insets.bottom + 2
            let padSide: CGFloat = 0

            let availW = max(geo.size.width  - padSide * 2, 200)
            let availH = max(geo.size.height - padTop - padBottom, 120)

            // 自动适配缩放：取宽高两个方向的较小值
            let autoS = min(availW / ScreenFit.refWidth,
                            availH / ScreenFit.refHeight)

            // 叠加用户的 XY 独立缩放
            let lay = layoutStore.layout
            let sx = autoS * lay.safeScaleX
            let sy = autoS * lay.safeScaleY

            // 缩放后画布实际占用的尺寸
            let drawnW = ScreenFit.refWidth  * sx
            let drawnH = ScreenFit.refHeight * sy

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    topBar
                    rpmBand
                    middleRow
                    Spacer(minLength: 0)   // ← 把底部两行推到最下面
                    bottomRow
                    debugPinRow
                }
                .frame(width: ScreenFit.refWidth, height: ScreenFit.refHeight)
                // XY 分别缩放
                .scaleEffect(x: sx, y: sy, anchor: .center)
                // 位移（按参考画布单位，跟着缩放一起走）
                .offset(x: lay.safeShiftX * sx, y: lay.safeShiftY * sy)
                .frame(width: drawnW, height: drawnH)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .padding(.top, padTop)
            .padding(.bottom, padBottom)
            .clipped()
            .background(sportBackground)
            .onAppear {
                weather.refreshIfNeeded()
                // 转速平滑：让数字和刻度条连续变化
                startRpmSmoothing()
                // 行程统计：GPS 模式下由这里喂速度
                startTripFeeding()
                // 已经在横屏就直接播，否则等尺寸就绪
                if ready { scheduleBoot(after: 0.15) }
            }
            .onChange(of: ready) { _, isReady in
                if isReady { scheduleBoot(after: 0.25) }
            }
            .onDisappear {
                stopRpmSmoothing()
                bootTimer?.invalidate()
                bootTimer = nil
                bootAnimating = false
                // 自检结束：平滑值直接对齐真实转速，避免从满量程慢慢滑下来
                rpmSmoother.snap(to: targetRpm)
                tripFeedTimer?.invalidate()
                tripFeedTimer = nil
            }
        }
        // 自检模式下让灯呼吸闪，用时间线驱动
        .onReceive(Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()) { _ in
            tickPulse()
        }
    }

    // MARK: - 自检动画控制

    /// 延迟一会儿再开动画，确保屏幕已经彻底转好、布局也稳定了
    private func scheduleBoot(after delay: Double) {
        guard !bootAnimating, bootProgress == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 再确认一次还没播过（防止重复触发）
            guard !bootAnimating, bootProgress == 0 else { return }
            startBootAnimation()
        }
    }

    /// 开始播放开机自检动画
    private func startBootAnimation() {
        bootTimer?.invalidate()
        bootAnimating = true
        bootProgress = 0
        // 播放自定义自检音效（有的话）
        BootSound.shared.play()
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [self] t in
            let elapsed = Date().timeIntervalSince(start)
            let p = min(elapsed / bootDuration, 1.0)
            // 0 → 1 → 0 的三角波
            let tri = p < 0.5 ? (p * 2) : (1 - p) * 2
            bootProgress = tri
            if p >= 1.0 {
                t.invalidate()
                bootTimer = nil
                bootAnimating = false
                bootProgress = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        bootTimer = timer
    }

    /// 自检动画期间显示的速度值
    private var displaySpeedValue: Double {
        if bootAnimating {
            return bootSpeedMax * bootProgress
        }
        return speed
    }

    /// 自检动画期间显示的转速值（已乘倍率）
    /// 目标转速（未平滑）
    private var targetRpm: Double {
        let raw: Double = isObd ? (obd.reading.rpm ?? 0) : mgr.data.rpm
        return raw * rpmStore.current.multiplier
    }

    private var displayRpmValue: Double {
        if bootAnimating {
            return rpmStore.current.scaleMax * bootProgress
        }
        return smoothRpm
    }

    /// 启动 60Hz 平滑：让 smoothRpm 连续追向 targetRpm
    ///
    /// 追法：每帧走剩余差值的 28%
    ///   · 60Hz 下约 0.12 秒追到 90%，看着「跟脚」但不抽搐
    ///   · 差值小于 1 rpm 直接吸附，避免永远追不到
    private func startRpmSmoothing() {
        guard rpmSmoothTimer == nil else { return }
        // 30Hz 足够：肉眼分辨不出 30 和 60 的差别，
        // 但 body 重绘次数减半，转速条就不会一顿一顿了
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            // 自检动画期间由动画自己驱动，不做平滑
            if bootAnimating { return }
            rpmSmoother.tick(target: targetRpm)
        }
        t.tolerance = 0.003
        RunLoop.main.add(t, forMode: .common)
        rpmSmoothTimer = t
    }

    /// 行程统计喂数据
    ///
    /// 里程必须按「仪表实际显示的速度」算：
    ///   · 速度来源 = GPS  → 用 GPS 速度（摩托固定 GPS）
    ///   · 速度来源 = OBD  → 由 ObdManager 在收到 010D 时自己喂，这里不动
    ///
    /// 每秒喂一次，既够准又不会把 TripMeter 刷爆。
    private func startTripFeeding() {
        guard tripFeedTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { _ in
            guard dataSource.isObdFamily else { return }

            // 判断这个数据源用的是不是 GPS 速度
            let useGps: Bool
            if dataSource == .motorcycle {
                useGps = true                      // 摩托固定 GPS
            } else {
                useGps = (SpeedSource.current == .gps)
            }
            guard useGps else { return }           // OBD 模式由 Manager 自己喂

            let kmh = gps.smoothSpeed
            guard kmh >= 0 else { return }
            let rpm = obd.reading.rpm ?? 0
            TripMeter.shared.update(speedKmh: kmh, powerW: 0, rpm: rpm)
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        tripFeedTimer = t
    }

    private func stopRpmSmoothing() {
        rpmSmoothTimer?.invalidate()
        rpmSmoothTimer = nil
    }

    // MARK: - 背景

    /// 当前数据源对应的独立仪表主题
    ///
    /// 电动车和 OBD2 各存一套，切换数据源时背景/颜色自动跟着换。
    /// 依赖 themeStore.revision，改设置后立刻重绘。
    private var dashTheme: DashTheme {
        _ = themeStore.revision          // 建立依赖，改主题时重算
        return DashThemeStore.shared.theme(for: dataSource)
    }

    @ViewBuilder
    private var sportBackground: some View {
        DashBackground(theme: dashTheme)
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
            //
            // OBD2 模式不显示刹车灯：标准 OBD2 PID 没有刹车信号，
            // 之前用「停车+转速」硬猜会误亮，索性不显示。
            HStack(spacing: 5) {
                if !isObd {
                    brakeLamp    // 刹车（红）
                }
                engineLamp   // 发动机（黄，MOS ≥ 60°C / 有故障码）
                coolantLamp  // 水温（黄，超过阈值）
                batteryLamp  // 电瓶（黄，电压过低 / 电量 < 26%）
            }
            .opacity(inSelfTest ? pulseOpacity : 1.0)

            Spacer(minLength: 4)

            // DIAGNOSTIC：点一下切回竖屏（原右上角旋转按钮的活）
            dashButton("DIAGNOSTIC", on: !inSelfTest) {
                NotificationCenter.default.post(name: .sportExitToPortrait, object: nil)
            }

            // SETTINGS：点一下打开设置（原右上角齿轮按钮的活）
            dashButton("SETTINGS", on: true) {
                NotificationCenter.default.post(name: .sportOpenSettings, object: nil)
            }
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

    /// 顶部的可点击胶囊按钮
    ///
    /// 原来右上角那两个圆形悬浮按钮已经去掉，
    /// 功能合并到这两个胶囊上，点击区域更大、也不挡仪表内容。
    private func dashButton(_ title: String, on: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
            // 扩大点击热区，手指好点
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    Text("\(Int(displayRpmValue.rounded()))")
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
                // 转速条：用 Canvas 一次画完
                //
                // 之前是 ZStack + 3 个 Rectangle + 20 个分隔条的 HStack，
                // 每帧都要重排布局（frame width 变化触发 layout pass），
                // 所以看起来一顿一顿。
                //
                // Canvas 是「立即绘制」，不进布局系统，60Hz 改动也不卡。
                Canvas { ctx, size in
                    let w = size.width
                    let h = size.height
                    let ratio = min(max(rpmRatio, 0), 1)
                    let fillW = w * ratio

                    // ① 底色
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                             with: .color(amber.opacity(0.12)))

                    // ② 红区（右侧 25%）
                    ctx.fill(Path(CGRect(x: w * 0.75, y: 0, width: w * 0.25, height: h)),
                             with: .color(red.opacity(0.22)))

                    // ③ 已填部分
                    if fillW > 0 {
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: fillW, height: h)),
                                 with: .color(ratio > 0.85 ? red : amber))
                    }

                    // ④ 分隔条（20 段，一次画完）
                    let segCount = 20
                    let segW = w / CGFloat(segCount)
                    for i in 1..<segCount {
                        let x = segW * CGFloat(i)
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)),
                                 with: .color(Color.black.opacity(0.85)))
                    }
                }
                .frame(height: 12)
                // 不在这里加 .animation：rpmRatio 由 60Hz 平滑定时器驱动，
                // 再叠一层 SwiftUI 动画会和它抢，看起来反而是「弹一下」。

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
        let maxV = rpmStore.current.scaleMax
        return stride(from: 0, through: maxV, by: maxV / 6).map { $0 }
    }

    // MARK: - 中间：速度 + 档位 + 油表

    private var middleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // 左侧：数据源连接指示灯
            VStack(spacing: 4) {
                Circle()
                    .fill(sourceConnected ? themeMgr.color(.ok) : amber.opacity(0.25))
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle().stroke(.white.opacity(0.5), lineWidth: 0.5)
                    }
                Rectangle()
                    .fill(amber.opacity(0.3))
                    .frame(width: 1, height: 26)
            }

            // 速度区：固定宽度，避免 0 → 299 位数变化把整行挤动
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(Int(displaySpeedValue.rounded()))")
                    .font(.system(size: 68, weight: .heavy, design: .monospaced))
                    .foregroundStyle(amber)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .shadow(color: amber.opacity(dashTheme.glow * 0.9), radius: 10)
                    .frame(minWidth: 132, alignment: .trailing)
                Text("km/h")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(amber.opacity(0.75))
                    .frame(width: 34, alignment: .leading)
            }
            .frame(width: 172, alignment: .leading)

            Spacer(minLength: 0)

            // 中间列：档位框严格垂直居中，小计里程单独贴在底部
            //
            // ⚠️ 档位框和小计里程不能放在同一个 ZStack 里：
            //   自检时速度/数据在变，ZStack 的内容尺寸会跟着抖，
            //   档位框就会被带着上下跳。这里用 overlay 把两件事分开，
            //   档位框只受外层 frame 控制，位置恒定不动。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if showGear {
                    if !isObd {
                        gearBoxes
                    } else {
                        obdGearBoxes
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 120, height: 150)
            .overlay(alignment: .bottom) {
                tripReadout
            }

            Spacer(minLength: 0)

            // 右侧：BMS 温度 + 油表
            //
            // 远驱：BMS 温度块 + 电量表
            // OBD2：油表（燃油液位 PID 2F）；设置里可关，或车不支持时自动隐藏
            if !isObd {
                HStack(alignment: .center, spacing: 10) {
                    if showBmsBlock {
                        bmsMosTempBlock
                            .offset(x: -6)
                    }
                    fuelGauge
                        .frame(width: 72, height: 116)
                }
            } else if showObdFuelGauge {
                fuelGauge
                    .frame(width: 72, height: 116)
            } else {
                // 隐藏时留同宽占位，保证速度/档位仍然居中
                Color.clear
                    .frame(width: 72, height: 116)
            }
        }
        // 固定高度：
        //   之前用 maxHeight: .infinity，高度会随内容（速度位数、里程文字）浮动，
        //   自检时数字不停变化 → 整行高度微调 → 档位框上下跳。
        //   锁死 150 后，档位框位置完全恒定。
        .frame(height: 150)
    }

    // MARK: - OBD2 档位

    /// OBD2 模式当前档位
    ///
    /// 优先级：
    ///   ① 设置里手动指定的档位（车读不到 A4 时的兜底）
    ///   ② PID 01A4 的真实档位
    ///   ③ 按转速/车速粗判 D/N
    private var obdGear: ObdGear {
        // ① 手动指定优先
        if let fixed = gearDisplayMode.gear {
            return fixed
        }
        // ② PID A4 真实档位
        if let raw = obd.reading.gear, raw > 0 {
            let g = ObdGear.decode(raw)
            if g != .unknown { return g }
        }
        // ③ 粗判
        let rpm = obd.reading.rpm ?? 0
        let spd = obd.reading.speedKmh ?? 0
        if spd < 1 && rpm > 300 {
            return .neutral
        }
        if rpm > 300 {
            return .drive
        }
        return .unknown
    }

    /// OBD2 档位框：单行横排
    ///
    ///   P R N D            自动挡
    ///   P R N D M 3        手动模式（M 亮，右边只显示当前一个数字）
    /// OBD2 档位框：按变速箱类型分两种显示
    ///
    ///   自动挡：P R N D 横排，挂手动时追加 M + 数字
    ///   手动挡：只显示当前一个字符，左侧带 «Gear» 小字
    @ViewBuilder
    private var obdGearBoxes: some View {
        // 自检阶段（没连上）固定显示 P，不抖动
        let active: ObdGear = obd.status.isConnected ? obdGear : .park

        if gearboxMode == .manual {
            manualGearBox(active)
        } else {
            autoGearBox(active)
        }
    }

    /// 自动挡（手自一体）：单行显示 «Gear: P»
    ///
    /// 之前是 P R N D 四个格子，占地方也看不清；
    /// 现在统一成 «Gear: 当前值»，左边小字标签，右边大字档位。
    /// 点一下可以在 P → R → N → D → M1…M6 之间循环切换，
    /// 车读不到 PID A4 时靠这个手动指定。
    private func autoGearBox(_ active: ObdGear) -> some View {
        // 自动挡下显示：P / R / N / D / M1~M6
        let text: String = {
            switch active {
            case .park:    return "P"
            case .reverse: return "R"
            case .neutral: return "N"
            case .drive:   return "D"
            case .manual(let n): return "M\(n)"
            case .unknown: return "–"
            }
        }()

        return Button {
            // 循环切换：P → R → N → D → M1 → … → M6 → P
            advanceGear()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Gear:")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(amber.opacity(0.55))

                Text(text)
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .foregroundStyle(amber)
                    .monospacedDigit()
                    .frame(minWidth: 16)
                    .shadow(color: amber.opacity(dashTheme.glow * 0.6), radius: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 120, height: 32)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(amber.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    /// 档位循环切换：P → R → N → D → M1 → M2 … M6 → P
    private func advanceGear() {
        switch obdGear {
        case .park:    gearDisplayMode = .reverse
        case .reverse: gearDisplayMode = .neutral
        case .neutral: gearDisplayMode = .drive
        case .drive:   gearDisplayMode = .m1
        case .manual(let n):
            if n >= 6 {
                gearDisplayMode = .park
            } else {
                switch n {
                case 1: gearDisplayMode = .m2
                case 2: gearDisplayMode = .m3
                case 3: gearDisplayMode = .m4
                case 4: gearDisplayMode = .m5
                default: gearDisplayMode = .m6
                }
            }
        case .unknown: gearDisplayMode = .park
        }
    }

    /// 手动挡：只显示一个字，左侧 «Gear» 小字
    ///
    ///   Gear N     ← 空挡
    ///   Gear 1     ← 一档
    ///   Gear 2     ← 二档
    private func manualGearBox(_ active: ObdGear) -> some View {
        // 手动挡下把 D 显示成 N（手动挡没有 D 这个概念）
        let ch: String = {
            switch active {
            case .park:    return "P"
            case .reverse: return "R"
            case .neutral: return "N"
            case .drive:   return "N"          // 前进但没指定具体档 → 按空挡显示
            case .manual(let n): return "\(n)"
            case .unknown: return "–"
            }
        }()

        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Gear:")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(amber.opacity(0.55))

            Text(ch)
                .font(.system(size: 20, weight: .heavy, design: .monospaced))
                .foregroundStyle(amber)
                .monospacedDigit()
                .frame(minWidth: 16)
                .shadow(color: amber.opacity(dashTheme.glow * 0.6), radius: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 120, height: 32)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(amber.opacity(0.25), lineWidth: 1)
        }
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

    /// 档位框（P / 1 / 2 / 3），在中间行里垂直居中
    ///
    /// 四个格子都是固定 24×24，整行高度恒定，
    /// 换挡时只改变颜色，不会让框上下移动。
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
        .frame(height: 24)
    }

    /// 小计里程 + 百公里电耗，贴在中间行底部
    private var tripReadout: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Text("ODO")
                    .font(.system(size: 6, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(amber.opacity(0.5))
                Text(trip.distanceText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(cyan)
                Text("km")
                    .font(.system(size: 6))
                    .foregroundStyle(amber.opacity(0.5))
            }

            // 右边一格：电摩显示电耗（kWh/100km），OBD 显示油耗（L/100km）
            HStack(spacing: 2) {
                Text(isObd ? obdFuelConsumptionText : trip.consumptionText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(amber)
                Text(isObd ? "L/100" : "kWh/100")
                    .font(.system(size: 6))
                    .foregroundStyle(amber.opacity(0.5))
            }
        }
    }

    /// OBD2 百公里油耗（L/100km）
    ///
    /// 优���用 PID 5E 的燃油消耗率（L/h）÷ 车速算，
    /// 没有 5E 就用 MAF 推算，都没有就显示 —
    private var obdFuelConsumptionText: String {
        // 用户可以在设置里关掉油耗显示
        guard showFuelConsumption else { return "—" }

        let speed = speed
        guard speed > 3 else { return "—" }

        // 优先用「燃油消耗率」(PID 5E)：
        //   有就用，没有就忽略这一格（不拿 MAF 硬凑，免得显示错的油耗）
        guard let rate = obd.reading.fuelRate, rate > 0 else { return "—" }

        // L/h ÷ km/h × 100 = L/100km
        let per100 = rate / speed * 100
        guard per100.isFinite, per100 >= 0, per100 < 200 else { return "—" }
        return String(format: "%.1f", per100)
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
            if isObd {
                // OBD2 模式：显示适配器状态和最近一次原始响应
                HStack(spacing: 6) {
                    Text("OBD")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.5))
                    Text(obd.status.text)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.75))
                    if !obd.dtcCodes.isEmpty {
                        Text("DTC:\(obd.dtcCodes.joined(separator: ","))")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(red)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                HStack(spacing: 6) {
                    Text("RAW")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.5))
                    Text(obd.lastRaw.isEmpty
                         ? "—"
                         : obd.lastRaw.replacingOccurrences(of: "\r", with: " ")
                                   .replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            } else {
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
                // 速度来源诊断：raw=原始转速值 rpm=换算后  spd=算出的时速
                HStack(spacing: 6) {
                    Text("SPD")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.5))
                    Text(String(format: "raw%d rpm%.0f spd%.1f",
                                Int(mgr.data.rawRpm),
                                mgr.data.rpm,
                                mgr.data.speed))
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: - 底部

    private var bottomRow: some View {
        HStack(spacing: 0) {
            if isObd {
                // ── OBD2 模式：固定六格，顺序恒定 ──
                //
                //   电压 | 水温 | 进气 | 节气门 | 负荷 | 怠速油耗
                //
                // 不再按「车支持什么」动态调整——位置固定，
                // 看惯了一眼就能找到。读不到的显示 «—»。
                bottomCell("电压", obdVoltageText, "V",
                           obdLowVoltage ? red : themeMgr.color(.voltage))
                divider
                bottomCell("水温", obdCoolantText, "°C",
                           obdHot ? red : themeMgr.color(.current))
                divider
                bottomCell("进气", obdIntakeText, "°C", themeMgr.color(.motorTemp))
                divider
                bottomCell("节气门", obdThrottleText, "%", themeMgr.color(.rpm))
                divider
                // 摩托车不显示负荷（很多摩托 ECU 不上报 0104），改用点火提前角
                if dataSource == .motorcycle {
                    bottomCell("点火", obdTimingText, "°", amber)
                } else {
                    bottomCell("负荷", obdLoadText, "%", amber)
                }
                divider
                bottomCell("怠速油耗", obdIdleFuelText, "L/h", themeMgr.color(.ok))
            } else {
                // ── 远驱模式：电动车数据 ──
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
                bottomCell("平均", trip.avgPowerText, "W", themeMgr.color(.motorTemp))
            }
        }
        .frame(height: 42)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(amber.opacity(0.35))
                .frame(height: 1)
        }
    }

    // MARK: OBD2 显示文字

    private var obdVoltageText: String {
        guard let v = obd.reading.batteryVoltage else { return "—" }
        return String(format: "%.1f", v)
    }
    private var obdCoolantText: String {
        guard let t = obd.reading.coolantTemp else { return "—" }
        return String(format: "%.0f", t)
    }
    private var obdIntakeText: String {
        guard let t = obd.reading.intakeTemp else { return "—" }
        return String(format: "%.0f", t)
    }
    private var obdThrottleText: String {
        guard let t = obd.reading.throttle else { return "—" }
        return String(format: "%.0f", t)
    }
    private var obdLoadText: String {
        guard let l = obd.reading.engineLoad else { return "—" }
        return String(format: "%.0f", l)
    }

    /// 点火提前角（PID 0E，单位「度」）
    ///
    /// 摩托车用这个替代「负荷」：
    /// 很多摩托 ECU 不上报 0104（发动机负荷），但普遍支持 010E。
    /// 值 = (A / 2) - 64，正常范围 -64° ~ +63.5°，
    /// 怠速通常 5~15°，急加速会退到 0 甚至负值（防爆震）。
    private var obdTimingText: String {
        guard let t = obd.reading.timingAdvance else { return "—" }
        return String(format: "%.1f", t)
    }

    /// 燃油液位百分比（PID 2F）
    private var obdFuelLevelText: String {
        guard let pct = obd.reading.fuelLevel else { return "—" }
        // 有些车返回 0~100，有些返回更大的范围，做个保护
        guard pct >= 0, pct <= 105 else { return "—" }
        return String(format: "%.0f", pct)
    }
    /// 怠速油耗（L/h）
    ///
    /// 停车怠速时的燃烧速率：
    ///   · 有 PID 5E（燃油消耗率）直接读
    ///   · 没有就用 MAF 推算（÷ 空燃比 ÷ 汽油密度）
    ///   · 车速太高时（在跑）不算怠速，显示 —
    private var obdIdleFuelText: String {
        // 在跑就不算怠速（3 km/h 以下视为停驶）
        let speed = obd.reading.speedKmh ?? 0
        guard speed <= 3 else { return "—" }

        // ① 燃油消耗率 L/h
        if let rate = obd.reading.fuelRate, rate > 0 {
            return String(format: "%.1f", rate)
        }
        // ② MAF 推算
        if let maf = obd.reading.maf, maf > 0 {
            // MAF g/s → 燃油 L/h：÷空燃比 14.7 ÷ 汽油密度 745 g/L × 3600
            let fuelGs = maf / 14.7
            let lph = fuelGs * 3600 / 745
            guard lph >= 0, lph < 20 else { return "—" }
            return String(format: "%.1f", lph)
        }
        return "—"
    }

    private var obdLowVoltage: Bool {
        guard let v = obd.reading.batteryVoltage else { return false }
        return v < batteryLow
    }
    private var obdHot: Bool {
        guard let t = obd.reading.coolantTemp else { return false }
        return t > coolantHigh
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
