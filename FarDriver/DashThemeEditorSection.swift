//
//  DashThemeEditorSection.swift
//  外观设置里的「仪表主题」区块
//
//  按当前数据源（电动车 / OBD2）分别编辑：
//    · 背景：纯色 / 图片 / 视频 / 动态粒子
//    · 颜色：强调色、转速色、正常色、警告色
//    · 效果：发光强度
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct DashThemeEditorSection: View {

    @ObservedObject var themeMgr: ThemeManager = .shared

    /// 当前数据源（决定编辑哪一套）
    @AppStorage("dataSource") private var dataSource: DataSource = .fardriver

    /// 正在编辑的主题副本（改完即存）
    @State private var theme: DashTheme = .fardriverDefault

    @State private var pickItem: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var busy = false
    @State private var errText: String?
    @State private var showErr = false

    var body: some View {
        Group {
            Section {
                // 当前编辑的是哪一套
                HStack {
                    Image(systemName: dataSource.icon)
                        .foregroundStyle(themeMgr.color(.ok))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("正在编辑：\(dataSource == .obd2 ? "OBD2 仪表" : "电动车仪表")")
                            .font(.subheadline)
                            .foregroundStyle(themeMgr.foreground)
                        Text("两套独立保存，切换数据源自动切换主题")
                            .font(.caption2)
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("仪表主题")
            }

            // ── 背景类型 ──
            Section {
                Picker("背景类型", selection: Binding(
                    get: { theme.backgroundKind },
                    set: { theme.backgroundKind = $0; save() }
                )) {
                    ForEach(DashTheme.BackgroundKind.allCases) { k in
                        Label(k.title, systemImage: k.icon).tag(k)
                    }
                }
                .pickerStyle(.segmented)

                // 纯色
                if theme.backgroundKind == .solid {
                    HStack {
                        Text("背景颜色").foregroundStyle(themeMgr.foreground)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: theme.bgHex) },
                            set: { theme.bgHex = $0.toHex() ?? "#000000"; save() }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }

                // 图片
                if theme.backgroundKind == .photo {
                    photoControls
                }

                // 视频
                if theme.backgroundKind == .video {
                    videoControls
                }

                // 粒子
                if theme.backgroundKind == .particles {
                    particleControls
                }

                // 图片/视频共用的调节
                if theme.backgroundKind == .photo || theme.backgroundKind == .video {
                    dimRow
                    blurRow
                }
            } header: {
                Text("背景")
            } footer: {
                Text("动态背景（视频/粒子）会持续刷新屏幕，耗电比静态背景高一些。")
                    .font(.caption2)
            }

            // ── 颜色 ──
            Section {
                colorRow("强调色（速度/档位）", keyPath: \.accentHex)
                colorRow("转速色", keyPath: \.rpmHex)
                colorRow("正常状态色", keyPath: \.okHex)
                colorRow("警告色", keyPath: \.warnHex)
            } header: {
                Text("界面颜色")
            } footer: {
                Text("这些颜色只作用于当前这套仪表的竞技风格。")
                    .font(.caption2)
            }

            // ── 效果 ──
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("发光强度").foregroundStyle(themeMgr.foreground)
                        Spacer()
                        Text(String(format: "%.0f%%", theme.glow * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(themeMgr.secondary)
                    }
                    Slider(value: Binding(
                        get: { theme.glow },
                        set: { theme.glow = $0; save() }
                    ), in: 0...1)
                    .tint(theme.accentColor)
                }

                Button {
                    DashThemeStore.shared.reset(dataSource)
                    theme = DashThemeStore.shared.theme(for: dataSource)
                } label: {
                    Label("恢复这套的默认外观", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("效果")
            }
        }
        .onAppear {
            theme = DashThemeStore.shared.theme(for: dataSource)
        }
        .onChange(of: dataSource) { _, _ in
            theme = DashThemeStore.shared.theme(for: dataSource)
        }
        .onChange(of: pickItem) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .video],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let u = urls.first else { return }
                importVideo(u)
            case .failure(let e):
                errText = e.localizedDescription
                showErr = true
            }
        }
        .alert("导入失败", isPresented: $showErr) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errText ?? "文件格式不支持")
        }
    }

    // MARK: - 图片控制

    private var photoControls: some View {
        Group {
            if let name = nonEmpty(theme.photoName),
               let url = DashThemeStore.mediaURL(name),
               let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            PhotosPicker(selection: $pickItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.badge.plus")
                        .foregroundStyle(theme.accentColor)
                    Text(nonEmpty(theme.photoName) == nil ? "从相册选背景图" : "换一张")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    if busy { ProgressView().scaleEffect(0.8) }
                }
            }

            if nonEmpty(theme.photoName) != nil {
                Button(role: .destructive) {
                    DashThemeStore.deleteMedia(theme.photoName)
                    theme.photoName = ""
                    save()
                } label: {
                    Label("删除背景图", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 视频控制

    private var videoControls: some View {
        Group {
            if let name = nonEmpty(theme.videoName) {
                HStack {
                    Image(systemName: "video.fill")
                        .foregroundStyle(theme.accentColor)
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(themeMgr.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            Button {
                showFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(theme.accentColor)
                    Text(nonEmpty(theme.videoName) == nil ? "从文件选视频" : "换一个视频")
                        .foregroundStyle(themeMgr.foreground)
                    Spacer()
                    if busy { ProgressView().scaleEffect(0.8) }
                }
            }

            Toggle("视频静音", isOn: Binding(
                get: { theme.videoMuted },
                set: { theme.videoMuted = $0; save() }
            ))

            if nonEmpty(theme.videoName) != nil {
                Button(role: .destructive) {
                    DashThemeStore.deleteMedia(theme.videoName)
                    theme.videoName = ""
                    save()
                } label: {
                    Label("删除背景视频", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 粒子控制

    private var particleControls: some View {
        Group {
            Picker("粒子样式", selection: Binding(
                get: { theme.particleStyle },
                set: { theme.particleStyle = $0; save() }
            )) {
                ForEach(DashTheme.ParticleStyle.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("密度").foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "%.0f%%", theme.particleIntensity * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.secondary)
                }
                Slider(value: Binding(
                    get: { theme.particleIntensity },
                    set: { theme.particleIntensity = $0; save() }
                ), in: 0.2...1)
                .tint(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("速度").foregroundStyle(themeMgr.foreground)
                    Spacer()
                    Text(String(format: "×%.1f", theme.particleSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeMgr.secondary)
                }
                Slider(value: Binding(
                    get: { theme.particleSpeed },
                    set: { theme.particleSpeed = $0; save() }
                ), in: 0.3...3.0)
                .tint(theme.accentColor)
            }
        }
    }

    // MARK: - 通用调节

    private var dimRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("暗度").foregroundStyle(themeMgr.foreground)
                Spacer()
                Text(String(format: "%.0f%%", theme.mediaDim * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(themeMgr.secondary)
            }
            Slider(value: Binding(
                get: { theme.mediaDim },
                set: { theme.mediaDim = $0; save() }
            ), in: 0...0.85)
            .tint(theme.accentColor)
        }
    }

    private var blurRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模糊").foregroundStyle(themeMgr.foreground)
                Spacer()
                Text(String(format: "%.0f", theme.mediaBlur))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(themeMgr.secondary)
            }
            Slider(value: Binding(
                get: { theme.mediaBlur },
                set: { theme.mediaBlur = $0; save() }
            ), in: 0...20)
            .tint(theme.accentColor)
        }
    }

    private func colorRow(_ title: String,
                          keyPath: WritableKeyPath<DashTheme, String>) -> some View {
        HStack {
            Text(title).foregroundStyle(themeMgr.foreground)
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(hex: theme[keyPath: keyPath]) },
                set: {
                    theme[keyPath: keyPath] = $0.toHex() ?? "#FFFFFF"
                    save()
                }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }

    // MARK: - 工具

    private func nonEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }

    private func save() {
        DashThemeStore.shared.save(theme, for: dataSource)
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        busy = true
        Task {
            defer { Task { @MainActor in busy = false; pickItem = nil } }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else {
                await MainActor.run {
                    errText = "读不到图片数据"
                    showErr = true
                }
                return
            }
            // 长边压到 2000 以内，避免背景图太大拖慢渲染
            let resized = img.downscaled(maxSide: 2000)
            let name = DashThemeStore.saveImage(resized, prefix: dataSource == .obd2 ? "obd" : "fd")
            await MainActor.run {
                if let name {
                    DashThemeStore.deleteMedia(theme.photoName)
                    theme.photoName = name
                    save()
                } else {
                    errText = "保存失败"
                    showErr = true
                }
            }
        }
    }

    private func importVideo(_ url: URL) {
        busy = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                Task { @MainActor in busy = false }
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("themevid-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)")
            try? FileManager.default.copyItem(at: url, to: tmp)
            let name = DashThemeStore.saveVideo(from: tmp,
                                                prefix: dataSource == .obd2 ? "obd" : "fd")
            try? FileManager.default.removeItem(at: tmp)
            await MainActor.run {
                if let name {
                    DashThemeStore.deleteMedia(theme.videoName)
                    theme.videoName = name
                    save()
                } else {
                    errText = "视频保存失败，换个格式试试"
                    showErr = true
                }
            }
        }
    }
}

// MARK: - 图片缩放工具

extension UIImage {
    /// 按最长边缩放
    func downscaled(maxSide: CGFloat) -> UIImage {
        let w = size.width, h = size.height
        let longest = max(w, h)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
