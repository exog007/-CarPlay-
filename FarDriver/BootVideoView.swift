//
//  BootVideoView.swift
//  开机动画设置：勾选开关 + 上传视频
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct BootVideoView: View {
    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject var bootVideo = BootVideo.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pickedVideo: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var importing = false
    @State private var showError = false
    @State private var errorText = ""

    @AppStorage("bootVideoEnabled") private var videoEnabled = false
    /// 画面适配模式：fill / fit / stretch
    @AppStorage("bootVideoFitMode") private var fitModeRaw: String = "fill"
    /// 额外缩放
    @AppStorage("bootVideoZoom") private var zoom: Double = 1.0
    /// 水平偏移
    @AppStorage("bootVideoOffsetX") private var offsetX: Double = 0
    /// 垂直偏移
    @AppStorage("bootVideoOffsetY") private var offsetY: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("开启开机动画", isOn: $videoEnabled)
                        .disabled(!bootVideo.hasVideo)
                } header: {
                    Text("开关")
                } footer: {
                    Text(bootVideo.hasVideo
                         ? "打开后，启动 App 会先全屏播放你上传的视频（横屏播放），播完自动进入竞技仪表的自检画面。"
                         : "需要先上传一段视频才能开启。")
                }

                Section {
                    if bootVideo.hasVideo {
                        HStack {
                            Image(systemName: "film.fill")
                                .foregroundStyle(themeMgr.color(.ok))
                            Text("已上传视频")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(String(format: "%.1f 秒", bootVideo.duration))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            BootVideo.shared.deleteVideo()
                            videoEnabled = false
                        } label: {
                            Label("删除视频", systemImage: "trash")
                        }
                    } else {
                        HStack {
                            Image(systemName: "film")
                                .foregroundStyle(themeMgr.secondary)
                            Text("还没上传视频")
                                .foregroundStyle(themeMgr.secondary)
                            Spacer()
                        }
                    }
                } header: {
                    Text("当前视频")
                }

                Section {
                    PhotosPicker(selection: $pickedVideo, matching: .videos) {
                        HStack {
                            Image(systemName: "video.badge.plus")
                                .foregroundStyle(themeMgr.color(.rpm))
                            Text("从相册选视频")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            if importing {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }

                    Button {
                        showFilePicker = true
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(themeMgr.color(.rpm))
                            Text("从文件选视频")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            if importing {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                } header: {
                    Text("上传")
                } footer: {
                    Text("视频会转成 720p mp4 存在本机，时长原样保留：视频多长就播多久。\n视频自带的声音会一起播放。")
                }

                // 画面适配：裁剪 / 拉伸 / 缩放 / 偏移
                Section {
                    Picker("画面适配", selection: $fitModeRaw) {
                        Text("填充（裁剪）").tag("fill")
                        Text("适应（留黑边）").tag("fit")
                        Text("拉伸（铺满变形）").tag("stretch")
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("缩放")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(String(format: "×%.2f", zoom))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $zoom, in: 0.5...2.0, step: 0.01)
                            .tint(themeMgr.color(.rpm))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("水平偏移")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(String(format: "%+.0f%%", offsetX * 100))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $offsetX, in: -0.5...0.5, step: 0.01)
                            .tint(themeMgr.color(.ok))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("垂直偏移")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(String(format: "%+.0f%%", offsetY * 100))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $offsetY, in: -0.5...0.5, step: 0.01)
                            .tint(themeMgr.color(.ok))
                    }

                    Button {
                        fitModeRaw = "fill"
                        zoom = 1.0
                        offsetX = 0
                        offsetY = 0
                    } label: {
                        Label("恢复默认适配", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("画面适配")
                } footer: {
                    Text("填充 = 铺满屏幕但裁掉一部分；适应 = 完整显示但可能留黑边；拉伸 = 强行铺满可能变形。\n如果需要画面左右移动，用水平偏移微调。")
                }
            }
            .navigationTitle("开机动画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
            .onChange(of: pickedVideo) { _, item in
                guard let item else { return }
                importFromPhotos(item)
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .video],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importFromFile(url)
                case .failure(let err):
                    errorText = err.localizedDescription
                    showError = true
                }
            }
            .alert("上传失败", isPresented: $showError) {
                Button("好", role: .cancel) { }
            } message: {
                Text(errorText.isEmpty ? "这个文件可能没有视频轨，或者格式不支持。" : errorText)
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    // MARK: - 导入

    private func importFromPhotos(_ item: PhotosPickerItem) {
        importing = true
        Task {
            defer {
                Task { @MainActor in
                    importing = false
                    pickedVideo = nil
                }
            }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    errorText = "读不到视频数据"
                    showError = true
                }
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("bootvid-\(UUID().uuidString).mov")
            do {
                try data.write(to: tmp, options: .atomic)
            } catch {
                await MainActor.run {
                    errorText = "临时文件写入失败"
                    showError = true
                }
                return
            }
            let ok = await BootVideo.shared.importVideo(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if !ok {
                await MainActor.run {
                    errorText = "这个视频无法处理，换个格式试试"
                    showError = true
                }
            }
        }
    }

    private func importFromFile(_ url: URL) {
        importing = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                Task { @MainActor in importing = false }
            }
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("bootvid-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: tmp)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
            } catch {
                await MainActor.run {
                    errorText = "文件读取失败"
                    showError = true
                }
                return
            }
            let ok = await BootVideo.shared.importVideo(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if !ok {
                await MainActor.run {
                    errorText = "这个文件没有可用的视频轨，或者格式不支持"
                    showError = true
                }
            }
        }
    }
}
