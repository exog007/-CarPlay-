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
                    Text("视频会转成 720p mp4 存在本机，时长原样保留：视频多长就播多久。\n播放时会静音，避免和自检音效重叠。")
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
