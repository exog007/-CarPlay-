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

    var body: some View {
        NavigationStack {
            List {
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
            Text("改完立刻生效，不用重启")
                .font(.caption2)
        }
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
