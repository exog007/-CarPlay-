//
//  RedlineSettingsView.swift
//  转速顶满爆闪的设置 + 实时预览
//
//  预览条和自己开车时完全一样（同一套 Canvas 绘制逻辑），
//  改参数立刻能看到效果，不用上车试。
//

import SwiftUI

struct RedlineSettingsView: View {

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject var store = RedlineStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 预览相位
    @State private var phase: Double = 0
    @State private var timer: Timer?
    /// 预览用的转速比例（0~1）
    @State private var previewRatio: Double = 1.0

    var body: some View {
        NavigationStack {
            List {
                previewSection
                toggleSection
                thresholdSection
                speedSection
                intensitySection
                resetSection
            }
            .navigationTitle("转速顶满爆闪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { startPreview() }
            .onDisappear { stopPreview() }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    // MARK: - 预览

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // 预览条
                Canvas { ctx, size in
                    let w = size.width
                    let h = size.height
                    let ratio = previewRatio
                    let fillW = w * ratio

                    let cfg = store.config
                    let flashing = cfg.enabled && ratio >= cfg.threshold
                    let flash = phase
                    let k = cfg.intensity

                    let red = Color(red: 0.85, green: 0.15, blue: 0.15)
                    let amber = Color(red: 0.95, green: 0.62, blue: 0.10)

                    // 底色
                    let baseAlpha: Double = flashing ? 0.12 + flash * 0.30 * k : 0.12
                    let baseColor: Color = flashing ? red : amber
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                             with: .color(baseColor.opacity(baseAlpha)))

                    // 红区
                    let zoneAlpha: Double = flashing ? 0.22 + flash * 0.35 * k : 0.22
                    ctx.fill(Path(CGRect(x: w * 0.75, y: 0, width: w * 0.25, height: h)),
                             with: .color(red.opacity(zoneAlpha)))

                    // 填充
                    if fillW > 0 {
                        let fillColor: Color
                        if flashing {
                            fillColor = flash > 0.55
                                ? Color(red: 1.0,
                                        green: 1.0 - 0.15 * (1 - k),
                                        blue: 1.0 - 0.15 * (1 - k))
                                : red
                        } else {
                            fillColor = ratio > 0.85 ? red : amber
                        }
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: fillW, height: h)),
                                 with: .color(fillColor))
                    }

                    // 分隔条
                    let segCount = 20
                    let segW = w / CGFloat(segCount)
                    for i in 1..<segCount {
                        let x = segW * CGFloat(i)
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)),
                                 with: .color(Color.black.opacity(0.85)))
                    }

                    // 外发光
                    if flashing {
                        let glowW = 1.0 + flash * 2.5 * k
                        ctx.stroke(
                            Path(CGRect(x: glowW / 2, y: glowW / 2,
                                        width: w - glowW, height: h - glowW)),
                            with: .color(red.opacity((0.35 + flash * 0.55) * k)),
                            lineWidth: glowW
                        )
                    }
                }
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                // 状态说明
                HStack {
                    Text(store.config.enabled ? "预览中" : "已关闭（不会闪）")
                        .font(.caption)
                        .foregroundStyle(themeMgr.secondary)
                    Spacer()
                    Text(String(format: "转速 %.0f%%", previewRatio * 100))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(previewRatio >= store.config.threshold
                                         ? themeMgr.color(.warn)
                                         : themeMgr.secondary)
                }

                // 拖动模拟不同转速
                Slider(value: $previewRatio, in: 0.5...1.0, step: 0.01)
                    .tint(themeMgr.color(.rpm))
            }
            .padding(.vertical, 4)
        } header: {
            Text("效果预览")
        } footer: {
            Text("拖动下面滑块模拟转速。超过阈值就会开始爆闪，和你开车时看到的一样。")
                .font(.caption2)
        }
    }

    // MARK: - 开关

    private var toggleSection: some View {
        Section {
            Toggle("启用转速顶满爆闪", isOn: Binding(
                get: { store.config.enabled },
                set: { v in
                    var c = store.config
                    c.enabled = v
                    store.config = c
                }
            ))
        } footer: {
            Text("转速接近满量程时，整个能量条红色爆闪，提醒该升档了。所有数据源通用。")
                .font(.caption2)
        }
    }

    // MARK: - 阈值

    private var thresholdSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("触发阈值")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(store.config.thresholdText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(themeMgr.color(.warn))
                }
                Slider(value: Binding(
                    get: { store.config.threshold },
                    set: { v in
                        var c = store.config
                        c.threshold = v
                        store.config = c
                    }
                ), in: 0.70...1.0, step: 0.01)
                .tint(themeMgr.color(.warn))
                Text("满量程的 \(store.config.thresholdText) 开始闪。设成 100% 就只有真顶到才闪。")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
            }
        } header: {
            Text("触发条件")
        }
    }

    // MARK: - 速度

    private var speedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("闪烁频率")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(store.config.hzText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(themeMgr.color(.power))
                }
                Slider(value: Binding(
                    get: { store.config.period },
                    set: { v in
                        var c = store.config
                        c.period = v
                        store.config = c
                    }
                ), in: 0.05...0.60, step: 0.01)
                .tint(themeMgr.color(.power))
                Text("滑块越左闪得越快。0.08 秒约 6Hz（很急）、0.16 秒约 3Hz（推荐）、0.4 秒约 1Hz（呼吸）")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
            }
        } header: {
            Text("闪烁速度")
        }
    }

    // MARK: - 强度

    private var intensitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("闪烁强度")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "%.0f%%", store.config.intensity * 100))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(themeMgr.color(.ok))
                }
                Slider(value: Binding(
                    get: { store.config.intensity },
                    set: { v in
                        var c = store.config
                        c.intensity = v
                        store.config = c
                    }
                ), in: 0.2...1.0, step: 0.05)
                .tint(themeMgr.color(.ok))
                Text("控制颜色变化幅度和外发光：低一点柔和，高一点刺眼。")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
            }
        } header: {
            Text("强度")
        }
    }

    // MARK: - 恢复默认

    private var resetSection: some View {
        Section {
            Button {
                store.config = .default
            } label: {
                Label("恢复默认", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("默认：阈值 97%、频率约 3Hz、强度 100%")
                .font(.caption2)
        }
    }

    // MARK: - 预览定时器

    private func startPreview() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.04, repeats: true) { _ in
            let cfg = store.config
            guard cfg.enabled else {
                if phase != 0 { phase = 0 }
                return
            }
            guard previewRatio >= cfg.threshold else {
                if phase != 0 { phase = 0 }
                return
            }
            let step = max(0.01, min(0.5, 0.04 / max(cfg.period, 0.02)))
            let p = phase + step
            phase = p >= 1.0 ? 0 : p
        }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPreview() {
        timer?.invalidate()
        timer = nil
        phase = 0
    }
}
