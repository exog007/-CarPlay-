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
    /// 搜索列表里当前选中的地点
    @State private var selectedItem: MKMapItem?
    /// 高德搜索结果
    @State private var amapPlaces: [AmapPlace] = []
    /// 高德选中的地点
    @State private var selectedAmap: AmapPlace?
    /// 这次搜索是否走高德
    @State private var useAmap = false
    /// 高德算出来的路线
    @State private var amapRoute: AmapRoute?
    /// 高德路线的画线对象
    @State private var routeOverlay: MKPolyline?
    /// 是否处于导航中（决定地图用 3D 跟车视角）
    @State private var navigating = false
    /// 出行方式
    @State private var travelMode: TravelMode = .scooter
    /// 当前走到第几条指令
    @State private var currentStepIndex = 0
    /// 导航相机跟随计时器
    @State private var navTimer: Timer?

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

            // 四周渐晕：中间清楚、边缘压黑（参考图那种边框泛黑效果）
            GeometryReader { g in
                let w = g.size.width
                let h = g.size.height
                ZStack {
                    // 径向渐晕
                    RadialGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.34),
                            .init(color: .black.opacity(0.35), location: 0.62),
                            .init(color: .black.opacity(0.88), location: 0.88),
                            .init(color: .black, location: 1.0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(w, h) * 0.60
                    )
                    // 上下再补一层，让顶部/底部文字更实
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.75), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: h * 0.16)
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: h * 0.20)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                // 导航中：顶部显示转向指引条
                if navigating, let step = currentStep {
                    navBanner(step)
                        .padding(.top, 6)
                }
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
            // 导航中：每来一个新位置就把 3D 相机跟过去
            if navigating {
                applyNavigationCamera()
            } else {
                // 没导航时只居中一次（避免用户手动拖地图被拉回去）
                if camera == .automatic { recenterMap() }
            }
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
            // 高德路线
            if let overlay = routeOverlay {
                MapPolyline(overlay)
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
                // 出行方式
                Section {
                    HStack(spacing: 8) {
                        ForEach(TravelMode.allCases) { m in
                            Button {
                                travelMode = m
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: m.icon)
                                        .font(.system(size: 16))
                                    Text(m.title)
                                        .font(.system(size: 9))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(travelMode == m
                                            ? themeMgr.color(.ok).opacity(0.9)
                                            : Color.clear)
                                .foregroundStyle(travelMode == m ? .white : .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                } header: {
                    Text("出行方式")
                }

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
                } header: {
                    Text("目的地")
                } footer: {
                    Text("输入地址或地点名，从结果里点一个选中，再点「开始导航」。")
                }

                if !results.isEmpty {
                    Section("搜索结果（点一下选中）") {
                        ForEach(results, id: \.self) { item in
                            Button {
                                selectedItem = item
                                selectedAmap = nil
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name ?? "未命名地点")
                                            .foregroundStyle(.primary)
                                        if let addr = item.placemark.title {
                                            Text(addr)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if let sel = selectedItem, sel == item {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }

                // 高德搜索结果
                if !amapPlaces.isEmpty {
                    Section("搜索结果 · 高德（点一下选中）") {
                        ForEach(amapPlaces) { p in
                            Button {
                                selectedAmap = p
                                selectedItem = nil
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name)
                                            .foregroundStyle(.primary)
                                        Text(p.address)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if p.distance > 0 {
                                        Text(p.distanceText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let sel = selectedAmap, sel.id == p.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }

                // 选中之后才出现「开始导航」（高德结果）
                if let sel = selectedAmap {
                    Section {
                        Button {
                            startAmapRoute(to: sel)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                Text("开始导航到「\(sel.name)」")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeMgr.color(.ok))
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    } header: {
                        Text("导航 · 高德")
                    } footer: {
                        Text("点「开始导航」后地图会切到 3D 跟车视角。")
                    }
                }

                // 选中之后才出现「开始导航」（MapKit 结果）
                if let sel = selectedItem {
                    Section {
                        Button {
                            startRoute(to: sel)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                Text("开始导航到「\(sel.name ?? "目的地")」")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeMgr.color(.ok))
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    } header: {
                        Text("导航")
                    } footer: {
                        Text("点「开始导航」后地图会切到 3D 跟车视角。")
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

    /// 搜索结果（高德优先，没 key 或失败就回退 MapKit）
    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        amapPlaces = []
        useAmap = AmapKey.configured

        if AmapKey.configured {
            AmapService.search(keyword: q, near: loc.location?.coordinate) { result in
                DispatchQueue.main.async {
                    searching = false
                    switch result {
                    case .success(let places):
                        amapPlaces = places
                        results = []
                    case .failure:
                        // 高德失败就回退 MapKit
                        useAmap = false
                        runMapKitSearch(q)
                    }
                }
            }
            return
        }
        runMapKitSearch(q)
    }

    /// MapKit 回退搜索
    private func runMapKitSearch(_ q: String) {
        searching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
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

    /// 用高德/MapKit 规划路线并进入 3D 导航视角
    private func startAmapRoute(to place: AmapPlace) {
        guard let from = loc.location?.coordinate else { return }
        AmapService.route(from: from, to: place.coordinate, mode: travelMode) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    amapRoute = r
                    // 用高德的坐标点造一条 MKPolyline 用来画线
                    var coords = r.points
                    routeOverlay = MKPolyline(coordinates: &coords, count: coords.count)
                    // 目的地标记
                    routeTarget = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                    routeTarget?.name = place.name
                    route = nil
                    selectedAmap = nil
                    showSearch = false
                    currentStepIndex = 0
                    beginNavigation()
                case .failure:
                    // 高德失败，退回 MapKit 路线
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                    item.name = place.name
                    startRoute(to: item)
                }
            }
        }
    }

    /// 规划路线并进入 3D 导航视角
    private func startRoute(to item: MKMapItem) {
        guard let from = loc.location?.coordinate else { return }
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = item
        req.transportType = travelMode.mapKitTransport
        MKDirections(request: req).calculate { resp, _ in
            DispatchQueue.main.async {
                guard let r = resp?.routes.first else { return }
                route = r
                routeOverlay = nil
                amapRoute = nil
                routeTarget = item
                showSearch = false
                // 进入导航：切 3D 跟车视角
                beginNavigation()
            }
        }
    }

    /// 3D 跟车视角：低头 55°、朝向车头、贴着当前位置
    private func applyNavigationCamera() {
        guard let l = loc.location else { return }
        // 优先用 GPS 的 course（真实行进方向），拿不到才用磁力计 heading
        let dir = l.course >= 0 ? l.course : loc.heading
        camera = .camera(MapCamera(
            centerCoordinate: l.coordinate,
            distance: 240,
            heading: dir,
            pitch: 58
        ))
    }

    /// 进入导航：开相机跟随 + 定位到第一条指令
    private func beginNavigation() {
        navigating = true
        currentStepIndex = 0
        applyNavigationCamera()
        navTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            guard navigating, let l = loc.location else { return }
            // 相机跟车
            applyNavigationCamera()
            // 判断当前在第几段：找到离当前位置最近的 step 起点
            updateCurrentStep(location: l)
        }
        RunLoop.main.add(t, forMode: .common)
        navTimer = t
    }

    /// 用当前位置找最近的 step，更新当前指令
    private func updateCurrentStep(location: CLLocation) {
        guard let r = amapRoute, !r.steps.isEmpty else { return }
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, s) in r.steps.enumerated() {
            let d = location.distance(from: CLLocation(latitude: s.start.latitude,
                                                       longitude: s.start.longitude))
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        // 只有明确靠近下一段（50 米内）才切换，避免来回跳
        if bestDist < 50, bestIdx != currentStepIndex {
            currentStepIndex = bestIdx
        }
    }

    private func endNavigation() {
        navTimer?.invalidate()
        navTimer = nil
        clearRoute()
    }

    private func clearRoute() {
        navTimer?.invalidate()
        navTimer = nil
        route = nil
        amapRoute = nil
        routeOverlay = nil
        routeTarget = nil
        selectedItem = nil
        selectedAmap = nil
        navigating = false
        currentStepIndex = 0
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

    // MARK: - 中间：左右分段能量条

    private var middleRow: some View {
        HStack(spacing: 0) {
            // 左：速度能量条（白色系）
            ZStack {
                SegmentArc(progress: speedRatio, tone: .plain, side: .left)
                    .frame(width: 190, height: 250)

                VStack(spacing: -4) {
                    Text("\(Int(speed.rounded()))")
                        .font(.system(size: 46, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("km/h")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .offset(x: 22)
            }
            .frame(width: 190, height: 250)

            Spacer(minLength: 0)

            // 右：电量能量条（黄绿渐变），数值是两个百分比（和参考图一致）
            ZStack {
                SegmentArc(progress: batteryPercent, tone: .energy, side: .right)
                    .frame(width: 190, height: 250)

                // 上：100% 刻度说明；下：当前电量
                VStack {
                    HStack(spacing: 3) {
                        Text("100%")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 26)

                    Spacer()

                    HStack(spacing: 3) {
                        Text("\(Int(batteryPercent * 100))%")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(batteryPercent < 0.3 ? accent : .white)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 26)
                }
                .frame(height: 200)
                .offset(x: -14)
            }
            .frame(width: 190, height: 250)
        }
    }

    // MARK: - 导航指引条（仿高德）

    /// 当前指令
    private var currentStep: AmapStep? {
        guard let r = amapRoute, currentStepIndex < r.steps.count else { return nil }
        return r.steps[currentStepIndex]
    }

    /// 剩余距离（从当前指令到终点）
    private var remainDistance: Int {
        guard let r = amapRoute else { return 0 }
        let idx = min(currentStepIndex, max(0, r.steps.count - 1))
        var sum = 0
        for i in idx..<r.steps.count {
            sum += r.steps[i].distance
        }
        return sum
    }

    /// 剩余时间
    private var remainDuration: Int {
        guard let r = amapRoute else { return 0 }
        let idx = min(currentStepIndex, max(0, r.steps.count - 1))
        var sum = 0
        for i in idx..<r.steps.count {
            sum += r.steps[i].duration
        }
        return sum
    }

    private func navBanner(_ step: AmapStep) -> some View {
        HStack(spacing: 10) {
            // 转向图标
            Image(systemName: turnIcon(step.action))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 1) {
                // 距离 + 动作
                Text(step.instruction)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.road.isEmpty {
                    Text(step.road)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // 剩余总量
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f", Double(remainDistance) / 1000.0) + " km")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(green)
                Text(remainText)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
            }

            // 结束导航
            Button {
                endNavigation()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(green.opacity(0.35), lineWidth: 1)
                )
        )
        .frame(maxWidth: 560)
    }

    private var remainText: String {
        let m = remainDuration / 60
        if m < 60 { return "\(m) 分钟" }
        return "\(m / 60) 小时 \(m % 60) 分"
    }

    /// 高德 action 文字 → SF Symbol
    private func turnIcon(_ action: String) -> String {
        let a = action
        if a.contains("左转") || a.contains("左") {
            if a.contains("掉头") { return "arrow.uturn.left" }
            return a.contains("急") ? "arrow.turn.up.left" : "arrow.turn.up.left"
        }
        if a.contains("右转") || a.contains("右") {
            return "arrow.turn.up.right"
        }
        if a.contains("掉头") { return "arrow.uturn.backward" }
        if a.contains("直行") { return "arrow.up" }
        if a.contains("到达") || a.contains("终点") { return "flag.checkered" }
        if a.contains("靠左") { return "arrow.up.left" }
        if a.contains("靠右") { return "arrow.up.right" }
        return "arrow.up"
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // 左：档位
            VStack {
                Spacer()
                gearChip(isParked ? "P" : (mgr.data.gear > 0 ? "\(mgr.data.gear)" : "—"),
                         active: isParked)
            }
            .frame(height: 74)

            Spacer(minLength: 6)

            // 中：指南针（同款）
            compass
                .frame(width: 190, height: 62)

            Spacer(minLength: 6)

            // 右：大号音乐播放器（和参考图同位置、同尺寸）
            nowPlayingCard

            // 再右：导航状态（有导航才显示）
            if let t = routeTarget {
                navStatus(name: t.name ?? "导航中",
                          distance: Double(amapRoute?.distance ?? Int(route?.distance ?? 0)))
                    .frame(width: 130)
            }
        }
        .frame(height: 78)
    }

    // MARK: - 指南针

    /// 参考图底部那种：刻度线 + 方位文字 + 当前度数
    private var compass: some View {
        // GPS course 优先，没有就用磁力计
        let deg = loc.location?.course ?? 0
        let heading = deg >= 0 ? deg : loc.heading

        return VStack(spacing: 2) {
            // 刻度条
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let mid = w / 2
                // 每 5° 一个小刻度，每 30° 一个大刻度
                for d in stride(from: -60, through: 60, by: 5) {
                    let x = mid + CGFloat(d) / 60.0 * (w / 2 - 6)
                    let isMajor = (d % 30 == 0)
                    let isCenter = (d == 0)
                    let len: CGFloat = isMajor ? h * 0.55 : (isCenter ? h * 0.8 : h * 0.32)
                    let color: Color = isCenter ? accent : .white.opacity(isMajor ? 0.75 : 0.35)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: h - len))
                    p.addLine(to: CGPoint(x: x, y: h))
                    ctx.stroke(p, with: .color(color),
                               style: StrokeStyle(lineWidth: isCenter ? 1.8 : 1, lineCap: .butt))
                }
            }
            .frame(height: 22)

            // 方位文字
            HStack(spacing: 0) {
                ForEach(CompassPoint.marks, id: \.offset) { m in
                    Text(m.name)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.5))
                    if m.offset < CompassPoint.marks.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 4)

            // 当前度数
            HStack(spacing: 3) {
                Text("\(Int(heading.rounded()))°")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(CompassPoint.name(for: heading))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: - 音乐播放器（大号卡片，仿参考图）

    private var nowPlayingCard: some View {
        HStack(spacing: 10) {
            // 大唱片图标
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.13))
                    .frame(width: 54, height: 54)
                if let art = np.artwork {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // 歌名
                Text(np.hasInfo ? np.title : "未在播放")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(np.hasInfo ? 0.95 : 0.45))
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)

                // 进度条
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(width: 130, height: 3)
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: max(0, CGFloat(np.progress) * 130), height: 3)
                }
                .animation(.linear(duration: 1), value: np.progress)

                // 时间
                HStack {
                    Text(np.hasInfo ? np.elapsedText : "0:00")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 0)
                    Text(np.hasInfo ? "-\(np.durationText)" : "-0:00")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(width: 130)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.35))
        )
    }

    /// 底部导航状态小条
    private func navStatus(name: String, distance: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.system(size: 10))
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            Text(String(format: "%.1fkm", distance / 1000))
                .font(.system(size: 9, design: .monospaced))
        }
        .foregroundStyle(themeMgr.color(.ok))
        .frame(maxWidth: 180)
    }

    private func gearChip(_ text: String, active: Bool) -> some View {        Text(text)
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

// MARK: - 指南针方位

enum CompassPoint {
    /// 刻度下方的方位文字（和参考图一致：南 西南 西 西北）
    struct Mark {
        let offset: Int
        let name: String
    }

    static let marks: [Mark] = [
        Mark(offset: 0, name: "南"),
        Mark(offset: 1, name: "西南"),
        Mark(offset: 2, name: "西"),
        Mark(offset: 3, name: "西北"),
    ]

    /// 度数 → 中文方位
    static func name(for deg: Double) -> String {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        switch d {
        case 22.5..<67.5:   return "东北"
        case 67.5..<112.5:  return "东"
        case 112.5..<157.5: return "东南"
        case 157.5..<202.5: return "南"
        case 202.5..<247.5: return "西南"
        case 247.5..<292.5: return "西"
        case 292.5..<337.5: return "西北"
        default:            return "北"
        }
    }
}

// MARK: - 分段能量条弧（参考图那种一段一段的刻度条）
//
// 和连续弧不同：沿弧线排一排独立的小短段，段间留空隙。
// 已填充的段是亮色（带渐变），未填充是暗灰。
//   左侧：白色系（速度）
//   右侧：黄→绿→黄 渐变（电量）

struct SegmentArc: View {
    enum Side { case left, right }
    /// 电量低时的警示色
    enum Tone {
        case plain      // 白色系
        case energy     // 黄色能量条
    }

    let progress: Double
    let tone: Tone
    let side: Side
    /// 段数（参考图约 28 段）
    var segments: Int = 28
    var lineWidth: CGFloat = 9

    /// 扫角范围
    private var startDeg: Double { side == .left ? 96 : 84 }
    private var endDeg: Double   { side == .left ? 268 : 272 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx: CGFloat = side == .left ? w * 0.90 : w * 0.10
            let cy: CGFloat = h / 2
            let radius = min(w * 0.84, h / 2 - lineWidth * 1.5)

            Canvas { ctx, _ in
                let span = endDeg - startDeg
                let step = span / Double(segments)
                let lit = Int((Double(segments) * progress).rounded())

                for i in 0..<segments {
                    let a0 = startDeg + step * Double(i)
                    // 每段留 42% 空隙
                    let a1 = a0 + step * 0.58

                    var path = Path()
                    let steps = max(3, Int(abs(a1 - a0) / 2))
                    for s in 0...steps {
                        let t = Double(s) / Double(steps)
                        let deg = a0 + (a1 - a0) * t
                        let rad = deg * Double.pi / 180
                        let p = CGPoint(x: cx + CGFloat(cos(rad)) * radius,
                                        y: cy + CGFloat(sin(rad)) * radius)
                        if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }

                    let isOn = i < lit
                    let color: Color
                    if !isOn {
                        color = .white.opacity(0.13)
                    } else if tone == .plain {
                        // 速度：暗→白，越靠上越亮
                        let t = Double(i) / Double(max(1, segments - 1))
                        color = Color(white: 0.55 + 0.45 * t)
                    } else {
                        // 电量：底部黄 → 中段绿 → 顶部黄（和参考图一致）
                        let t = Double(i) / Double(max(1, segments - 1))
                        color = SegmentArc.energyColor(t)
                    }

                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }

                // 两端端点小方块（参考图两端的方形标记）
                for deg in [startDeg, endDeg] {
                    let rad = deg * Double.pi / 180
                    let p = CGPoint(x: cx + CGFloat(cos(rad)) * radius,
                                    y: cy + CGFloat(sin(rad)) * radius)
                    let r: CGFloat = 3.5
                    let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 1),
                               with: .color(.white.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1.2))
                }
            }
        }
    }

    /// 能量条配色：0 → 黄，0.35 → 绿，0.7 → 绿，1 → 亮黄
    static func energyColor(_ t: Double) -> Color {
        if t < 0.35 {
            // 黄 → 绿
            let k = t / 0.35
            return Color(.sRGB,
                         red: 1.0 - 0.55 * k,
                         green: 0.78 + 0.10 * k,
                         blue: 0.0 + 0.25 * k,
                         opacity: 1)
        } else if t < 0.72 {
            // 绿段
            return Color(.sRGB, red: 0.30, green: 0.90, blue: 0.32, opacity: 1)
        } else {
            // 绿 → 亮黄（顶部）
            let k = (t - 0.72) / 0.28
            return Color(.sRGB,
                         red: 0.30 + 0.95 * k,
                         green: 0.90 - 0.05 * k,
                         blue: 0.32 - 0.32 * k,
                         opacity: 1)
        }
    }
}

// MARK: - 预览

#Preview {
    ZStack {
        Color.black
        HStack {
            SegmentArc(progress: 0.6, tone: .plain, side: .left)
                .frame(width: 170, height: 230)
            SegmentArc(progress: 0.65, tone: .energy, side: .right)
                .frame(width: 170, height: 230)
        }
    }
}
