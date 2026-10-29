//
//  AppearanceView.swift
//  外观自定义：背景 + 仪表颜色
//

import SwiftUI
import PhotosUI

struct AppearanceView: View {
    @ObservedObject var themeMgr: ThemeManager
    @Environment(\.dismiss) private var dismiss

    /// 相册选图
    @State private var pickedItem: PhotosPickerItem?
    @State private var photoBusy = false
    @State private var showPhotoError = false

    /// 竞技风格背景图
    @State private var sportPickItem: PhotosPickerItem?
    @State private var sportPhotoBusy = false

    var body: some View {
        NavigationStack {
            List {
                dashStyleSection
                sportSection
                sportPhotoSection
                rpmSection
                batterySection
                previewSection
                backgroundTypeSection
                backgroundDetailSection
                colorSection
                opacitySection
                resetSection
            }
            .navigationTitle("外观")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                loadPickedPhoto(item)
            }
            .onChange(of: sportPickItem) { _, item in
                guard let item else { return }
                loadSportPhoto(item)
            }
            .alert("图片读取失败", isPresented: $showPhotoError) {
                Button("好", role: .cancel) { }
            } message: {
                Text("这个图片可能损坏或格式不支持，换一张试试。")
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    /// 从相册取图并设为背景
    private func loadPickedPhoto(_ item: PhotosPickerItem) {
        photoBusy = true
        Task {
            defer {
                Task { @MainActor in photoBusy = false }
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else {
                await MainActor.run { showPhotoError = true }
                return
            }
            let ok = await MainActor.run { themeMgr.setBackgroundPhoto(img) }
            if !ok {
                await MainActor.run { showPhotoError = true }
            }
            await MainActor.run { pickedItem = nil }
        }
    }

    /// 从相册取图并设为竞技风格背景
    private func loadSportPhoto(_ item: PhotosPickerItem) {
        sportPhotoBusy = true
        Task {
            defer {
                Task { @MainActor in sportPhotoBusy = false }
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else {
                await MainActor.run { showPhotoError = true }
                return
            }
            let ok = await MainActor.run { themeMgr.setSportPhoto(img) }
            if !ok {
                await MainActor.run { showPhotoError = true }
            }
            await MainActor.run { sportPickItem = nil }
        }
    }

    // MARK: - 仪表风格

    private var dashStyleSection: some View {
        Section {
            ForEach(DashStyle.allCases) { style in
                Button {
                    themeMgr.theme.dashStyle = style
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: style.icon)
                            .font(.system(size: 18))
                            .frame(width: 26)
                            .foregroundStyle(themeMgr.theme.dashStyle == style
                                             ? themeMgr.color(.ok)
                                             : themeMgr.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(themeMgr.foreground)
                            Text(style.subtitle)
                                .font(.caption2)
                                .foregroundStyle(themeMgr.secondary)
                        }
                        Spacer()
                        if themeMgr.theme.dashStyle == style {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(themeMgr.color(.ok))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("横屏仪表风格")
        } footer: {
            Text("竞技风格只在横屏生效，竖屏仍用标准布局。横屏时右上角也有一个按钮可以快速切换。")
                .font(.caption2)
        }
    }

    // MARK: - 竞技风格设置

    private var sportSection: some View {
        Section {
            HStack {
                Text("竞技底色")
                    .foregroundStyle(themeMgr.foreground)
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { Color(hex: themeMgr.theme.sportBgHex) },
                    set: { themeMgr.theme.sportBgHex = $0.toHex() ?? "#000000" }
                ), supportsOpacity: false)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("发光强度")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "%.0f%%", themeMgr.theme.sportGlow * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.secondary)
                }
                Slider(value: Binding(
                    get: { themeMgr.theme.sportGlow },
                    set: { themeMgr.theme.sportGlow = $0 }
                ), in: 0...1)
                .tint(themeMgr.color(.power))
            }
        } header: {
            Text("竞技风格")
        } footer: {
            Text("底色建议深色（纯黑/深灰），文字和线框的颜色跟下面「仪表颜色」里的「功率」和「转速」走。")
                .font(.caption2)
        }
    }

    // MARK: - 竞技：背景图

    private var sportPhotoSection: some View {
        Section {
            // 预览缩略图
            if let img = themeMgr.sportPhotoImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            PhotosPicker(selection: $sportPickItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.badge.plus")
                        .foregroundStyle(themeMgr.color(.power))
                    Text(themeMgr.sportPhotoImage == nil ? "给竞技仪表换背景图" : "换一张图片")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    if sportPhotoBusy {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }

            if themeMgr.sportPhotoImage != nil {
                Button(role: .destructive) {
                    themeMgr.clearSportPhoto()
                } label: {
                    Label("删掉图片，用纯色底", systemImage: "trash")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("图片暗度")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text(String(format: "%.0f%%", themeMgr.theme.sportPhotoDim * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Slider(value: Binding(
                        get: { themeMgr.theme.sportPhotoDim },
                        set: { themeMgr.theme.sportPhotoDim = $0 }
                    ), in: 0...0.85)
                    .tint(themeMgr.color(.power))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("图片模糊")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text(String(format: "%.0f", themeMgr.theme.sportPhotoBlur))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Slider(value: Binding(
                        get: { themeMgr.theme.sportPhotoBlur },
                        set: { themeMgr.theme.sportPhotoBlur = $0 }
                    ), in: 0...20)
                    .tint(themeMgr.color(.power))
                }
            }
        } header: {
            Text("竞技背景图")
        } footer: {
            Text("竞技仪表可以用图片当背景，和上面「背景类型」里的图片互不影响。暗度调高一点，琥珀色数字更清楚。")
                .font(.caption2)
        }
    }

    // MARK: - 转速显示

    private var rpmSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("转速倍率")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "×%.0f", themeMgr.theme.rpmMultiplier))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.color(.power))
                }
                Slider(value: Binding(
                    get: { themeMgr.theme.rpmMultiplier },
                    set: { themeMgr.theme.rpmMultiplier = $0 }
                ), in: 1...20, step: 1)
                .tint(themeMgr.color(.power))
                Text("原厂报 \(Int(mgrRpmSample)) rpm ✕ \(Int(themeMgr.theme.rpmMultiplier)) = 显示 \(Int(mgrRpmSample * themeMgr.theme.rpmMultiplier)) rpm")
                    .font(.caption2)
                    .foregroundStyle(themeMgr.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("转速表满量程")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text("\(Int(themeMgr.theme.rpmScaleMax)) rpm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.secondary)
                }
                Slider(value: Binding(
                    get: { themeMgr.theme.rpmScaleMax },
                    set: { themeMgr.theme.rpmScaleMax = $0 }
                ), in: 4000...30000, step: 1000)
                .tint(themeMgr.color(.rpm))
            }
        } header: {
            Text("转速显示")
        } footer: {
            Text("竞技仪表上的转速 = 原厂转速 × 倍率。原厂报 100 rpm，倍率 10 就显示 1000 rpm。满量程决定刻度条跑满时对应多少。")
                .font(.caption2)
        }
    }

    /// 示例用的原厂转速
    private var mgrRpmSample: Double { 100 }

    // MARK: - 电量表

    private var batterySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("满电电压")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "%.1f V", themeMgr.theme.battFullVoltage))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.color(.ok))
                }
                Slider(value: Binding(
                    get: { themeMgr.theme.battFullVoltage },
                    set: { themeMgr.theme.battFullVoltage = $0 }
                ), in: 20...120, step: 0.1)
                .tint(themeMgr.color(.ok))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("没电电压")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "%.1f V", themeMgr.theme.battEmptyVoltage))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.color(.warn))
                }
                Slider(value: Binding(
                    get: { themeMgr.theme.battEmptyVoltage },
                    set: { themeMgr.theme.battEmptyVoltage = $0 }
                ), in: 10...110, step: 0.1)
                .tint(themeMgr.color(.warn))
            }

            // 当前电压换算示例
            HStack {
                Text("当前电压")
                    .foregroundStyle(themeMgr.foreground)
                Spacer()
                Text(String(format: "%.1f V", sampleVoltage))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(themeMgr.secondary)
                Text("→")
                    .foregroundStyle(themeMgr.secondary)
                Text(samplePercentText)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(themeMgr.color(.ok))
            }
        } header: {
            Text("仪表电量表")
        } footer: {
            Text("竞技仪表右下角的指针表按这两个阈值线性换算：满电压 = 100%，没电电压 = 0%。21 串三元锂建议满 90.3V / 没电 63V。")
                .font(.caption2)
        }
    }

    /// 当前控制器电压（没连就用满电值做示例）
    private var sampleVoltage: Double {
        let v = ControllerManager.shared.data.voltage
        return v > 1 ? v : themeMgr.theme.battFullVoltage
    }

    /// 用示例电压算出来的百分比文字
    private var samplePercentText: String {
        let pct = BatteryPercent.compute(voltage: sampleVoltage,
                                         full: themeMgr.theme.battFullVoltage,
                                         empty: themeMgr.theme.battEmptyVoltage)
        return "\(Int(pct * 100))%"
    }

    // MARK: - 预览

    private var previewSection: some View {
        Section {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    miniGauge("转速", "3200", themeMgr.color(.rpm))
                    miniGauge("功率", "1200", themeMgr.color(.power))
                }
                HStack(spacing: 10) {
                    miniStat("电压", "82.1", themeMgr.color(.voltage))
                    miniStat("电流", "12.3", themeMgr.color(.current))
                    miniStat("OK", "正常", themeMgr.color(.ok))
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("预览")
        }
    }

    private func miniGauge(_ title: String, _ value: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(themeMgr.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(c)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func miniStat(_ title: String, _ value: String, _ c: Color) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(themeMgr.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(c)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(themeMgr.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 背景类型

    private var backgroundTypeSection: some View {
        Section("背景方式") {
            Picker("", selection: Binding(
                get: { themeMgr.theme.backgroundType },
                set: { themeMgr.theme.backgroundType = $0 }
            )) {
                ForEach(BackgroundType.allCases, id: \.self) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(themeMgr.cardBG)
        }
    }

    // MARK: - 背景细节

    @ViewBuilder
    private var backgroundDetailSection: some View {
        switch themeMgr.theme.backgroundType {
        case .preset:
            Section("主题") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(ThemePresets.all) { p in
                        presetChip(p)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(themeMgr.cardBG)
            }

        case .solid:
            Section("背景色") {
                ColorPaletteView(selectedHex: themeMgr.theme.solidHex) { hex in
                    themeMgr.theme.solidHex = hex
                }
                .listRowBackground(themeMgr.cardBG)
            }

        case .gradient:
            Section("渐变起始色") {
                ColorPaletteView(selectedHex: themeMgr.theme.gradientStart) { hex in
                    themeMgr.theme.gradientStart = hex
                }
                .listRowBackground(themeMgr.cardBG)
            }
            Section("渐变结束色") {
                ColorPaletteView(selectedHex: themeMgr.theme.gradientEnd) { hex in
                    themeMgr.theme.gradientEnd = hex
                }
                .listRowBackground(themeMgr.cardBG)
            }

        case .photo:
            photoSection
        }
    }

    // MARK: - 相册图片背景

    private var photoSection: some View {
        Group {
            Section {
                // 当前图片预览
                if let img = themeMgr.photoImage {
                    VStack(spacing: 8) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 160)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                Color.black.opacity(themeMgr.theme.photoDim)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .overlay(alignment: .topLeading) {
                                Text("当前背景")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.black.opacity(0.6))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                    .padding(8)
                            }
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .foregroundStyle(themeMgr.color(.rpm))
                        Text("还没有选图片")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                    }
                }

                // 从相册选
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    HStack {
                        if photoBusy {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundStyle(themeMgr.color(.rpm))
                        }
                        Text(photoBusy ? "正在处理…" : (themeMgr.photoImage == nil ? "从相册选择图片" : "换一张图片"))
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(themeMgr.secondary)
                    }
                }
                .disabled(photoBusy)

                // 删除
                if themeMgr.photoImage != nil {
                    Button(role: .destructive) {
                        themeMgr.clearBackgroundPhoto()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("删除背景图")
                        }
                    }
                }
            } header: {
                Text("背景图片")
            } footer: {
                Text("选好的图片会存到本机，重装 App 前都有效。图片会自动压缩，不占太多空间。")
                    .font(.caption2)
            }
            .listRowBackground(themeMgr.cardBG)

            // 模糊 / 遮罩调节
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("模糊")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text(String(format: "%.0f", themeMgr.theme.photoBlur))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Slider(value: Binding(
                        get: { themeMgr.theme.photoBlur },
                        set: { themeMgr.theme.photoBlur = $0 }
                    ), in: 0...20, step: 1)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("暗度（让字更清楚）")
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text(String(format: "%.0f%%", themeMgr.theme.photoDim * 100))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Slider(value: Binding(
                        get: { themeMgr.theme.photoDim },
                        set: { themeMgr.theme.photoDim = $0 }
                    ), in: 0...0.8, step: 0.05)
                }
                .padding(.vertical, 2)
            } header: {
                Text("调节")
            } footer: {
                Text("背景太花的时候，把「暗度」调高一点，仪表数字更清楚。")
                    .font(.caption2)
            }
            .listRowBackground(themeMgr.cardBG)
        }
    }

    private func presetChip(_ p: ThemePreset) -> some View {
        let selected = themeMgr.theme.presetId == p.id
        return Button {
            themeMgr.theme.presetId = p.id
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(hex: p.start), Color(hex: p.end)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: 52)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? themeMgr.color(.rpm) : Color.clear, lineWidth: 2)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(themeMgr.color(.rpm))
                                .padding(4)
                        }
                    }
                Text(p.name)
                    .font(.caption2)
                    .foregroundStyle(selected ? themeMgr.foreground : themeMgr.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 仪表颜色

    private var colorSection: some View {
        Section {
            // 字体亮度：一次调所有颜色的强弱
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("字体亮度")
                        .font(.subheadline)
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "%.0f%%", themeMgr.theme.textBrightness * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.secondary)
                }
                Slider(value: Binding(
                    get: { themeMgr.theme.textBrightness },
                    set: { themeMgr.theme.textBrightness = $0 }
                ), in: 0.5...1.6)
                .tint(themeMgr.color(.rpm))

                // 实时预览条：用几个典型颜色展示当前亮度
                HStack(spacing: 8) {
                    brightnessSwatch("转速", themeMgr.color(.rpm))
                    brightnessSwatch("功率", themeMgr.color(.power))
                    brightnessSwatch("电压", themeMgr.color(.voltage))
                    brightnessSwatch("正常", themeMgr.color(.ok))
                }

                HStack {
                    Text("暗（夜里不晃眼）")
                        .font(.system(size: 9))
                        .foregroundStyle(themeMgr.secondary)
                    Spacer()
                    Text("亮（阳光下更清楚）")
                        .font(.system(size: 9))
                        .foregroundStyle(themeMgr.secondary)
                }
            }
            .padding(.vertical, 2)
            .listRowBackground(themeMgr.cardBG)

            ForEach(ColorSlot.allCases) { slot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(slot.title)
                            .font(.subheadline)
                            .foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Circle()
                            .fill(themeMgr.color(slot))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(themeMgr.isLight ? Color.black.opacity(0.1) : Color.white.opacity(0.2), lineWidth: 1))
                        Text(themeMgr.theme.hex(for: slot))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeMgr.secondary)
                    }
                    ColorPaletteView(selectedHex: themeMgr.theme.hex(for: slot)) { hex in
                        themeMgr.theme.setColor(hex, for: slot)
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(themeMgr.cardBG)
            }
        } header: {
            Text("仪表颜色")
        } footer: {
            Text("「字体亮度」是所有颜色统一调亮/调暗的系数，改了不用逐个调。100% = 调色板原色。改完立刻生效，不用重启。")
                .font(.caption2)
        }
    }

    /// 亮度预览小色块
    private func brightnessSwatch(_ title: String, _ c: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(c)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(themeMgr.isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.07))
            )
    }

    // MARK: - 卡片透明度

    private var opacitySection: some View {
        Section {
            HStack {
                Text("卡片透明度")
                    .foregroundStyle(themeMgr.foreground)
                Spacer()
                Text(String(format: "%.0f%%", themeMgr.theme.cardOpacity * 100))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(themeMgr.secondary)
            }
            Slider(value: Binding(
                get: { themeMgr.theme.cardOpacity },
                set: { themeMgr.theme.cardOpacity = $0 }
            ), in: 0.15...0.95)
        }
        .listRowBackground(themeMgr.cardBG)
    }

    // MARK: - 重置

    private var resetSection: some View {
        Section {
            Button("只重置颜色") {
                themeMgr.resetColors()
            }
            .foregroundStyle(.orange)
            .listRowBackground(themeMgr.cardBG)

            Button("全部恢复默认", role: .destructive) {
                themeMgr.reset()
            }
            .listRowBackground(themeMgr.cardBG)
        }
    }
}

// MARK: - 色板

struct ColorPaletteView: View {
    let selectedHex: String
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
            ForEach(ColorUtil.palette, id: \.self) { hex in
                Button {
                    onPick(hex)
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(height: 30)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                        }
                        .overlay {
                            if selectedHex.uppercased() == hex.uppercased() {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(ColorUtil.isLight(hex: hex) ? .black : .white)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
