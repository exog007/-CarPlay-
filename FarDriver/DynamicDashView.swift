//
//  DynamicDashView.swift
//  动态仪表：全屏地图 + 左侧速度圆环 + 右侧转速圆环 + 顶部四项数据
//
//  布局（横屏）：
//    顶部：日期时间 / 四项数据 / 右侧按钮
//    中间：左速度圆环 ── 地图 ── 右转速圆环
//    底部：媒体信息条（暂留位置）
//

import SwiftUI
import MapKit

struct DynamicDashView: View {
    @ObservedObject var mgr: ControllerManager
    @ObservedObject var themeMgr: ThemeManager
    @ObservedObject var gps: GpsSpeed
    @ObservedObject var trip = TripMeter.shared
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var loc = LocationService.shared
    @ObservedObject var np = NowPlayingService.shared

    /// 地图相机位置
    @State private var camera: MapCameraPosition = .automatic
    /// 长按后弹出搜索
    @State private var showSearch = false
    /// 搜索框文字
    @State private var searchText = ""
    /// 搜索结果
    @State private var results: [MKMapItem] = []
    /// 正在搜索
    @State private var searching = false
    /// 导航中的目标
    @State private var routeTarget: MKMapItem?
    /// 到目标的路线
    @State private var route: MKRoute?

    /// 融合车速
    private var speed: Double { gps.fused(with: mgr.data.speed) }

    private var theme: AppTheme { themeMgr.theme }

    /// 放大后的转速（和竞技仪表一致）
    private var displayRpm: Double { mgr.data.rpm * theme.rpmMultiplier }

    /// 转速百分比
    private var rpmRatio: Double {
        guard theme.rpmScaleMax > 0 else { return 0 }
        return min(max(displayRpm / theme.rpmScaleMax, 0), 1)
    }

    /// 速度百分比（满量程 200 km/h）
    private var speedRatio: Double {
        min(max(speed / 200.0, 0), 1)
    }

    /// 电量百分比
    private var batteryPercent: Double {
        guard mgr.status.isConnected else { return 0 }
        return BatteryPercent.compute(voltage: mgr.data.voltage,
                                      full: theme.battFullVoltage,
                                      empty: theme.battEmptyVoltage)
    }

    private var accent: Color { themeMgr.color(.power) }
    private var green: Color { themeMgr.color(.ok) }
    private var cyan: Color { themeMgr.color(.rpm) }

    var body: some View {
        ZStack {
            // 底色
            Color.black.ignoresSafeArea()

            // 地图铺满背景，四周压暗
            mapBackground

            // 上下遮罩，让文字更清楚
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.85), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 80)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                middleRow
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear {
            loc.start()
            weather.refreshIfNeeded()
            recenterMap()
        }
        .onChange(of: loc.location) { _, _ in
            // 位置第一次拿到时把地图居中
            recenterMap()
        }
    }

    // MARK: - 地图

    private var mapBackground: some View {
        Map(position: $camera) {
            if let l = loc.location {
                Annotation("", coordinate: l.coordinate) {
                    // 蓝色定位点
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.25))
                            .frame(width: 34, height: 34)
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    }
                }
            }
            // 导航路线
            if let route {
                MapPolyline(route.polyline)
                    .stroke(themeMgr.color(.ok),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            // 目的地标记
            if let target = routeTarget {
                Marker(item: target)
                    .tint(themeMgr.color(.power))
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControlVisibility(.hidden)
        .ignoresSafeArea()
        .opacity(0.55)
        // 长按 → 打开搜索
        .onLongPressGesture(minimumDuration: 0.45) {
            showSearch = true
        }
        .sheet(isPresented: $showSearch) {
            navSearchSheet
        }
    }

    // MARK: - 导航搜索

    private var navSearchSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索目的地", text: $searchText)
                            .submitLabel(.search)
                            .onSubmit { runSearch() }
                        if searching {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                    Button("搜索") { runSearch() }
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("输入地址或地点名，从结果里点一个开始导航")
                }

                if !results.isEmpty {
                    Section("搜索结果") {
                        ForEach(results, id: \.self) { item in
                            Button {
                                startRoute(to: item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "未命名地点")
                                        .foregroundStyle(.primary)
                                    if let addr = item.placemark.title {
                                        Text(addr)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if routeTarget != nil {
                    Section {
                        Button(role: .destructive) {
                            clearRoute()
                        } label: {
                            Label("结束导航", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("导航")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        showSearch = false
                    }
                }
            }
        }
    }

    /// 用 MapKit 本地搜索
    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        // 以当前位置为中心，搜索半径 30km
        if let c = loc.location?.coordinate {
            req.region = MKCoordinateRegion(center: c,
                                            latitudinalMeters: 30000,
                                            longitudinalMeters: 30000)
        }
        MKLocalSearch(request: req).start { resp, _ in
            DispatchQueue.main.async {
                searching = false
                results = resp?.mapItems ?? []
            }
        }
    }

    /// 规划路线
    private func startRoute(to item: MKMapItem) {
        guard let from = loc.location?.coordinate else { return }
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = item
        req.transportType = .automobile
        MKDirections(request: req).calculate { resp, _ in
            DispatchQueue.main.async {
                guard let r = resp?.routes.first else { return }
                route = r
                routeTarget = item
                showSearch = false
                // 把地图缩放到能看见整条路线
                camera = .rect(r.polyline.boundingMapRect)
            }
        }
    }

    private func clearRoute() {
        route = nil
        routeTarget = nil
        showSearch = false
        recenterMap()
    }

    private func recenterMap() {
        guard let l = loc.location else { return }
        camera = .region(MKCoordinateRegion(
            center: l.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        ))
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左：日期时间
            VStack(alignment: .leading, spacing: -1) {
                Text(dateText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Text(timeText)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 120, alignment: .leading)

            Spacer(minLength: 8)

            // 中：四项数据
            HStack(spacing: 0) {
                topStat("电压", String(format: "%.1f", mgr.data.voltage), "V", cyan)
                statDivider
                topStat("MOS", "\(mgr.data.mosTemp)", "°C",
                        mgr.data.mosTemp > 60 ? accent : .white)
                statDivider
                topStat("电流", String(format: "%.1f", mgr.data.current), "A",
                        mgr.data.isRegen ? green : .white)
                statDivider
                topStat("小计", trip.distanceText, "km", .white)
            }
            .fixedSize()

            Spacer(minLength: 8)

            // 右：天气 + 切换按钮
            HStack(spacing: 10) {
                if let t = weather.temperature {
                    HStack(spacing: 3) {
                        Image(systemName: weather.symbolName)
                            .font(.system(size: 12))
                        Text("\(Int(t.rounded()))°")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .frame(height: 44)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 14)
    }

    private func topStat(_ title: String, _ value: String, _ unit: String,
                         _ color: Color) -> some View {
        VStack(spacing: -1) {
            Text(title)
                .font(.system(size: 7, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(unit)
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 62)
    }

    // MARK: - 中间：左右圆环

    private var middleRow: some View {
        HStack(spacing: 0) {
            // 左：速度圆环
            RingGauge(
                progress: speedRatio,
                color: .white,
                segments: 34,
                lineWidth: 6,
                startAngle: 130,
                sweep: 240
            ) {
                VStack(spacing: -2) {
                    Text("\(Int(speed.rounded()))")
                        .font(.system(size: 40, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("km/h")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 160, height: 160)

            Spacer(minLength: 0)

            // 右：转速圆环
            RingGauge(
                progress: rpmRatio,
                color: green,
                segments: 34,
                lineWidth: 6,
                startAngle: -50,
                sweep: -240
            ) {
                VStack(spacing: -2) {
                    Text("\(Int(displayRpm.rounded()))")
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(green)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("rpm")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(width: 110)
            }
            .frame(width: 160, height: 160)
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // 左：档位
            gearChip(isParked ? "P" : (mgr.data.gear > 0 ? "\(mgr.data.gear)" : "—"),
                     active: isParked)

            Spacer(minLength: 8)

            // 中：媒体信息
            mediaBar

            Spacer(minLength: 8)

            // 右：导航状态 + 电量
            HStack(spacing: 8) {
                if let r = route, let t = routeTarget {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 10))
                        Text(t.name ?? "导航中")
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                        Text(String(format: "%.1fkm", r.distance / 1000))
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundStyle(themeMgr.color(.ok))
                    .frame(maxWidth: 180)
                }
                Image(systemName: "battery.100percent")
                    .font(.system(size: 11))
                    .foregroundStyle(batteryPercent < 0.3 ? accent : green)
                Text("\(Int(batteryPercent * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .frame(height: 28)
    }

    /// 媒体条：封面 + 歌名/歌手 + 进度
    private var mediaBar: some View {
        HStack(spacing: 8) {
            // 封面
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.12))
                    .frame(width: 26, height: 26)
                if let art = np.artwork {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: np.hasInfo ? "music.note" : "music.note.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            if np.hasInfo {
                VStack(alignment: .leading, spacing: 1) {
                    // 歌名
                    Text(np.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                    // 歌手 · 进度
                    HStack(spacing: 5) {
                        Text(np.artist)
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                        if np.duration > 0 {
                            Text("\(np.elapsedText)/\(np.durationText)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                // 进度条
                if np.duration > 0 {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.15))
                            .frame(width: 54, height: 2.5)
                        Capsule()
                            .fill(green)
                            .frame(width: max(0, CGFloat(np.progress) * 54), height: 2.5)
                    }
                    .animation(.linear(duration: 1), value: np.progress)
                }
            } else {
                Text("未在播放")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func gearChip(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy, design: .monospaced))
            .foregroundStyle(active ? .black : .white)
            .frame(width: 24, height: 22)
            .background(active ? accent : .white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// P 档（和竞技仪表一致，读控制器真实信号）
    private var isParked: Bool {
        guard mgr.status.isConnected, mgr.data.e2Seen else { return false }
        return mgr.data.pGearOn
    }

    // MARK: - 时间

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: Date())
    }
}

// MARK: - 分段圆环

/// 分段式圆环刻度（参考动态仪表风格）
///
/// - progress: 0~1 当前进度
/// - segments: 总段数（约 34 段，和参考图接近）
/// - startAngle / sweep: 起始角和扫角，度。正数顺时针
struct RingGauge<Content: View>: View {
    let progress: Double
    let color: Color
    let segments: Int
    let lineWidth: CGFloat
    let startAngle: Double
    let sweep: Double
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2 - lineWidth
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Canvas { ctx, _ in
                    let gapRatio = 0.28     // 每段之间留 28% 空隙
                    let segSweep = sweep / Double(segments)
                    let lit = Int((Double(segments) * progress).rounded())

                    for i in 0..<segments {
                        let a0 = startAngle + segSweep * Double(i)
                        let a1 = a0 + segSweep * (1 - gapRatio)
                        var path = Path()
                        let steps = max(2, Int(abs(a1 - a0) / 3))
                        for s in 0...steps {
                            let t = Double(s) / Double(steps)
                            let deg = a0 + (a1 - a0) * t
                            let rad = deg * Double.pi / 180
                            let p = CGPoint(x: center.x + CGFloat(cos(rad)) * radius,
                                            y: center.y + CGFloat(sin(rad)) * radius)
                            if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                        let isLit = i < lit
                        ctx.stroke(path,
                                   with: .color(isLit ? color : color.opacity(0.16)),
                                   style: StrokeStyle(lineWidth: isLit ? lineWidth : lineWidth * 0.85,
                                                      lineCap: .butt))
                    }
                }
                content
            }
        }
    }
}

// MARK: - 预览

#Preview {
    ZStack {
        Color.black
        RingGauge(progress: 0.6, color: .green, segments: 34, lineWidth: 6,
                  startAngle: 130, sweep: 240) {
            Text("42").font(.system(size: 40, weight: .light, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 160, height: 160)
    }
}
