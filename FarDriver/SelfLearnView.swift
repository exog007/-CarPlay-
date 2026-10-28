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

    @State private var running = false
    @State private var elapsed: Double = 0
    @State private var timer: Timer?
    @State private var result: String?
    @State private var showConfirm = false

    // 三层确认
    @State private var wheelLifted = false     // 勾选：后轮已悬空
    @State private var nobodyNear = false      // 勾选：周围没人
    @State private var typedWord = ""          // 手打「自学」两个字
    @State private var armCountdown = 0        // 倒计时 5 4 3 2 1
    @State private var countdownTimer: Timer?

    /// 两道勾选 + 手打确认词，三样都齐了才能点
    private var canArm: Bool {
        wheelLifted && nobodyNear && typedWord == "自学" && mgr.status.isConnected
    }

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

                // 风险说明
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        RiskRow("①", "车会自己窜出去",
                                "没悬空的话，自学习时电机会带着车往前跑")
                        RiskRow("②", "电机会突然抖动或反转",
                                "头几秒控制器还分不清相序，动作是乱的")
                        RiskRow("③", "轮子被卡住会发热",
                                "后轮转不动但还在通电，MOS 和线圈会烫")
                    }
                    Text("自学习本身不改参数、不写 FLASH，失败可以重来。它的危险在操作，不在控制器。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } header: {
                    Label("真实风险", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
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
                        // ---- 第一步：逐项确认 ----
                        VStack(alignment: .leading, spacing: 12) {
                            Text("第 1 步：逐项确认")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)

                            Toggle(isOn: $wheelLifted) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("后轮已经完全悬空")
                                        .font(.subheadline)
                                    Text("车架在支架上，后轮离地转得起来")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.orange)

                            Toggle(isOn: $nobodyNear) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("周围没人，我也不站在车旁")
                                        .font(.subheadline)
                                    Text("电机会突然抖动或反转")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.orange)
                        }
                        .padding(.vertical, 4)

                        // ---- 第二步：手打确认词 ----
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第 2 步：手动输入「自学」两个字")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                            TextField("在这里输入：自学", text: $typedWord)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color(white: 0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .autocorrectionDisabled()
                            if !typedWord.isEmpty && typedWord != "自学" {
                                Text("输入不对，要正好是「自学」两个字")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)

                        // ---- 第三步：倒计时后才会点亮 ----
                        if armCountdown > 0 {
                            HStack {
                                ProgressView()
                                Text("\(armCountdown) 秒后可以点，先确认后轮真的离地了")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Button {
                            showConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text(canArm && armCountdown == 0 ? "开始自学习" : "开始自学习（先完成上面两步）")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(!canArm || armCountdown > 0)
                    }

                    // 取消自学：任何时候都能点
                    Button {
                        cancelSelfLearn(force: true)
                    } label: {
                        HStack {
                            Image(systemName: "stop.circle.fill")
                            Text(running ? "取消自学" : "取消自学（强制停止）")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!mgr.status.isConnected)
                } header: {
                    Text("操作")
                } footer: {
                    Text("「取消自学」会立刻给控制器发停止指令，不管当前有没有在自学。\n\n⚠️ 自学习指令为试验性实现，未在真机验证过。如果点了没反应，说明指令格式不对，需要抓官方 App 的蓝牙日志才能修。")
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
                countdownTimer?.invalidate()
                countdownTimer = nil
            }
            // 三道确认齐了就启动 5 秒冷静期，期间还能反悔
            .onChange(of: canArm) { _, ok in
                countdownTimer?.invalidate()
                countdownTimer = nil
                if ok && !running {
                    armCountdown = 5
                    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                        if armCountdown > 1 {
                            armCountdown -= 1
                        } else {
                            armCountdown = 0
                            countdownTimer?.invalidate()
                            countdownTimer = nil
                        }
                    }
                    if let t = countdownTimer {
                        RunLoop.current.add(t, forMode: .common)
                    }
                } else {
                    armCountdown = 0
                }
            }
            .confirmationDialog("最后一次确认：后轮悬空了吗？",
                                isPresented: $showConfirm,
                                titleVisibility: .visible) {
                Button("确认，立刻开始自学习", role: .destructive) {
                    startSelfLearn()
                }
                Button("再等等", role: .cancel) {
                    // 取消就重置确认状态，下次要重新勾选
                    wheelLifted = false
                    nobodyNear = false
                    typedWord = ""
                    armCountdown = 0
                }
            } message: {
                Text("""
                点下去电机会立刻转动。

                • 后轮必须离地
                • 周围不能有人
                • 随时可以点「取消自学」

                停不下来就断控制器电源。
                """)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 操作

    private func startSelfLearn() {
        guard mgr.status.isConnected else { return }
        running = true
        elapsed = 0
        result = nil
        // 用了就清空，下次必须重新确认
        wheelLifted = false
        nobodyNear = false
        typedWord = ""
        armCountdown = 0
        countdownTimer?.invalidate()
        countdownTimer = nil
        mgr.startSelfLearn { ok in
            DispatchQueue.main.async {
                if !ok {
                    running = false
                    result = "指令发送失败：\(mgr.uploadError ?? "未知原因")"
                }
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
        if let t = timer {
            RunLoop.current.add(t, forMode: .common)
        }
    }

    /// 取消自学习
    /// - Parameter force: true 时不管当前状态都发一次停止指令（手动点按钮用）
    private func cancelSelfLearn(force: Bool = false) {
        timer?.invalidate()
        timer = nil
        let wasRunning = running
        running = false
        // 手动点「取消自学」时，不管界面认为在不在自学，都发一次停止
        if force || wasRunning {
            let ok = mgr.stopSelfLearn()
            if force {
                result = ok ? "已发送停止指令" : "停止指令发送失败：\(mgr.uploadError ?? "未知原因")"
            }
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

private struct RiskRow: View {
    let mark: String
    let title: String
    let detail: String
    init(_ mark: String, _ title: String, _ detail: String) {
        self.mark = mark
        self.title = title
        self.detail = detail
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(mark)
                .font(.caption.bold())
                .foregroundStyle(.red)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.red)
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
