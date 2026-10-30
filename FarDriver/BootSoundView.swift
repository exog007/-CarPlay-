//
//  BootSoundView.swift
//  自检音效设置：开关 + 从相册/文件导入
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct BootSoundView: View {
    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject var bootSound = BootSound.shared
    @Environment(\.dismiss) private var dismiss

    /// 从相册选视频
    @State private var pickedVideo: PhotosPickerItem?
    /// 从文件选音频
    @State private var showFilePicker = false
    /// 正在导入
    @State private var importing = false
    /// 导入失败
    @State private var showError = false
    @State private var errorText = ""

    @AppStorage("bootSoundEnabled") private var soundEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("播放自检音效", isOn: $soundEnabled)
                } header: {
                    Text("开关")
                } footer: {
                    Text("关闭后，进入竞技仪表时不会播放音效，自检动画照常播放。")
                }

                Section {
                    // 当前音效信息
                    if bootSound.hasSound {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundStyle(themeMgr.color(.ok))
                            Text("已设置音效")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            Text(String(format: "%.1f 秒", bootSound.duration))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            BootSound.shared.play()
                        } label: {
                            Label("试听", systemImage: "play.circle.fill")
                        }
                        Button(role: .destructive) {
                            BootSound.shared.deleteSound()
                        } label: {
                            Label("删除音效", systemImage: "trash")
                        }
                    } else {
                        HStack {
                            Image(systemName: "waveform.slash")
                                .foregroundStyle(themeMgr.secondary)
                            Text("还没设置音效")
                                .foregroundStyle(themeMgr.secondary)
                            Spacer()
                        }
                    }
                } header: {
                    Text("当前音效")
                }

                Section {
                    // 从相册选视频（自动抽音轨）
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

                    // 从文件 App 选音频
                    Button {
                        showFilePicker = true
                    } label: {
                        HStack {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(themeMgr.color(.rpm))
                            Text("从文件选音频")
                                .foregroundStyle(themeMgr.foreground)
                            Spacer()
                            if importing {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                } header: {
                    Text("导入")
                } footer: {
                    Text("选视频会自动提取里面的声音。选音频支持 mp3 / m4a / wav / aac 等常见格式。\n导入的音效会转成 m4a 存在本机，重装 App 前一直有效。")
                }
            }
            .navigationTitle("自检音效")
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
                importFromVideo(item)
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.audio, .movie, .mpeg4Movie, .quickTimeMovie],
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
            .alert("导入失败", isPresented: $showError) {
                Button("好", role: .cancel) { }
            } message: {
                Text(errorText.isEmpty ? "这个文件可能没有音轨，或者格式不支持。" : errorText)
            }
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    // MARK: - 导入

    /// 从相册视频导入
    private func importFromVideo(_ item: PhotosPickerItem) {
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
            // 写到临时文件再交给 AVAsset
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("boot-import-\(UUID().uuidString).mov")
            do {
                try data.write(to: tmp, options: .atomic)
            } catch {
                await MainActor.run {
                    errorText = "临时文件写入失败"
                    showError = true
                }
                return
            }
            let ok = await BootSound.shared.importMedia(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if !ok {
                await MainActor.run {
                    errorText = "这个视频里没有可用的音轨"
                    showError = true
                }
            }
        }
    }

    /// 从「文件」App 导入
    private func importFromFile(_ url: URL) {
        importing = true
        // 安全作用域资源
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                Task { @MainActor in importing = false }
            }
            // 拷到临时目录再处理，避免作用域失效
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("boot-import-\(UUID().uuidString)\(url.pathExtension.isEmpty ? "" : "." + url.pathExtension)")
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
            let ok = await BootSound.shared.importMedia(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if !ok {
                await MainActor.run {
                    errorText = "这个文件没有可用的音轨，或者格式不支持"
                    showError = true
                }
            }
        }
    }
}
