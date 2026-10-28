//
//  SelfLearnView.swift
//  电机自学习（相序 / 角度自动识别）
//
//  ⚠️ 危险操作：自学习会让电机转动。必须在后轮悬空、人离开车的情况下进行。
//
//  官方流程（来自远驱 App 2.2.7 文案）：
//    「即将进入自学习状态 → 进入 / 取消」
//    「取消自学」
//    「即将进入测试角度状态」
//    「即将进入取消跟随状态」
//

import SwiftUI

struct SelfLearnView: View {
    @ObservedObject var mgr: ControllerManager
    @Environment(\.dismiss) private var dismiss

    @State private var confirmed = false
    @State private var running = false
    @State private var elapsed: Double = 0
    @State private var timer: Timer?
    @State private var result: String?
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            List {
                // 安全警告
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.red)
                            Text("开始前必须做到")
                                .font(.headline)
                                .foregroundStyle(.red)
                        }
                        BulletRow("后轮必须完全悬空", "把车放支架上，后轮离地")
                        BulletRow("人不站在车旁", "电机会自己转起来")
                        BulletRow("控制器已连接", "没连上不能自学")
                        BulletRow("电量充足", "电压别太低")
                    }
                    .padding(.vertical, 4)
                }

                // 流程说明
                Section("自学习流程") {
                    StepRow(n: 1, text: "点「开始自学习」")
                    StepRow(n: 2, text: "电机自动转动，识别相序和角度")
                    StepRow(n: 3, text: "自动停止后转动转把，检查正反转")
                    StepRow(n: 4, text: "方向对了就完成，不对就再来一次")
                }

                // 状态
                Section("状态") {
                    HStack {
                        Text("控制器")
                        Spacer()
                        Text(mgr.status.isConnected ? "已连接" : "未连接")
                            .font(.subheadline.bold())
                            .foregroundStyle(mgr.status.isConnected ? Color.green : Color.red)
                    }
                    if running {
                        HStack {
                            Text("自学习中")
                                .foregroundStyle(.orange)
                            Spacer()
                            Text(String(format: "%.0f 秒", elapsed))
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                    if let r = result {
                        Text(r)
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                // 操作
                Section {
                    if !running {
                        Button {
                            showConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("开始自学习")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(!mgr.status.isConnected)
                    } else {
                        Button {
                            cancelSelfLearn()
                        } label: {
                            HStack {
                                Image(systemName: "stop.circle.fill")
                                Text("取消自学")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text("⚠️ 自学习指令为试验性实现，未在真机验证过。如果点了没反应，说明指令格式不对，需要抓官方 App 的蓝牙日志才能修。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                // 说明
                Section {
                    Text("""
                    本 App 只发送「进入/取消自学习」指令，具体识别过程由控制器自己完成。

                    如果连续多次自学习失败，可能是：
                    • 电机霍尔线松动或断路
                    • 相线接触不良
                    • 电机本体故障

                    这些需要检查硬件，不是软件问题。
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("电机自学习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        cancelSelfLearn()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
            .confirmationDialog("确认后轮已经悬空了吗？",
                                isPresented: $showConfirm,
                                titleVisibility: .visible) {
                Button("后轮已悬空，开始自学习", role: .destructive) {
                    startSelfLearn()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("电机会立刻开始转动。确认车已经架稳、后轮离地、周围没有人。")
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 操作

    private func startSelfLearn() {
        guard mgr.status.isConnected else { return }
        running = true
        elapsed = 0
        result = nil
        mgr.startSelfLearn { ok in
            if !ok {
                running = false
                result = "指令发送失败：\(mgr.uploadError ?? "未知原因")"
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
            // 30 秒还没结束就算超时
            if elapsed >= 30 {
                cancelSelfLearn()
                result = "30 秒没有收到完成信号，已自动停止。请检查电机接线。"
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func cancelSelfLearn() {
        timer?.invalidate()
        timer = nil
        if running {
            mgr.stopSelfLearn()
            running = false
        }
    }
}

// MARK: - 小组件

private struct BulletRow: View {
    let title: String
    let detail: String
    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StepRow: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Color.cyan.opacity(0.25))
                .foregroundStyle(.cyan)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
        }
    }
}
