//
//  DashLayoutEditorView.swift
//  仪表布局微调：XY 独立缩放 + 位移，带实时预览
//
//  预览是一个真实的 16:9 屏幕轮廓，里面画仪表的简化版，
//  调整滑块时预览立刻跟着变，所见即所得。
//

import SwiftUI

struct DashLayoutEditorView: View {

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject private var store = DashLayoutStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // ── 预览 ──
                Section {
                    DashLayoutPreview(layout: store.layout)
                        .frame(height: 190)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                } header: {
                    Text("预览")
                } footer: {
                    Text("外框代表手机屏幕（含灵动岛和底部横条）。虚线框是安全区，内容超出会被挡住。")
                        .font(.caption2)
                }

                // ── 缩放 ──
                Section {
                    sliderRow(title: "横向缩放",
                              value: Binding(
                                get: { store.layout.scaleX },
                                set: { store.setScale(x: $0, y: store.layout.scaleY) }
                              ),
                              range: 0.70...1.30,
                              format: { String(format: "×%.2f", $0) },
                              color: themeMgr.color(.rpm))

                    sliderRow(title: "纵向缩放",
                              value: Binding(
                                get: { store.layout.scaleY },
                                set: { store.setScale(x: store.layout.scaleX, y: $0) }
                              ),
                              range: 0.70...1.30,
                              format: { String(format: "×%.2f", $0) },
                              color: themeMgr.color(.rpm))

                    Button {
                        // XY 一起缩放（保持比例）
                        let v = store.layout.scaleX
                        store.setScale(x: v, y: v)
                    } label: {
                        Label("把纵向对齐到横向", systemImage: "arrow.left.and.right")
                    }

                    Button {
                        store.setScale(x: 1.0, y: 1.0)
                    } label: {
                        Label("缩放恢复 100%", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("缩放")
                } footer: {
                    Text("单独调横向或纵向可以修正「左右切边」或「上下顶出」。")
                        .font(.caption2)
                }

                // ── 位移 ──
                Section {
                    sliderRow(title: "水平位移",
                              value: Binding(
                                get: { store.layout.shiftX },
                                set: { store.setShift(x: $0, y: store.layout.shiftY) }
                              ),
                              range: -60...60,
                              format: { String(format: "%+.0f pt", $0) },
                              color: themeMgr.color(.ok))

                    sliderRow(title: "垂直位移",
                              value: Binding(
                                get: { store.layout.shiftY },
                                set: { store.setShift(x: store.layout.shiftX, y: $0) }
                              ),
                              range: -60...60,
                              format: { String(format: "%+.0f pt", $0) },
                              color: themeMgr.color(.ok))

                    HStack(spacing: 8) {
                        Button("居中") {
                            store.setShift(x: 0, y: 0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                        Button("上移") {
                            store.setShift(x: store.layout.shiftX, y: store.layout.shiftY - 5)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("下移") {
                            store.setShift(x: store.layout.shiftX, y: store.layout.shiftY + 5)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        Button("左移") {
                            store.setShift(x: store.layout.shiftX - 5, y: store.layout.shiftY)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                        Button("右移") {
                            store.setShift(x: store.layout.shiftX + 5, y: store.layout.shiftY)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } header: {
                    Text("位移")
                } footer: {
                    Text("正数往右下挪，负数往左上挪。")
                        .font(.caption2)
                }

                // ── 重置 ──
                Section {
                    Button(role: .destructive) {
                        store.reset()
                    } label: {
                        Label("全部恢复默认", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("仪表布局")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeMgr.backgroundView)
        }
        .preferredColorScheme(themeMgr.isLight ? .light : .dark)
    }

    /// 通用滑块行
    private func sliderRow(title: String, value: Binding<Double>,
                           range: ClosedRange<Double>,
                           format: @escaping (Double) -> String,
                           color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(themeMgr.foreground)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(color)
            }
            Slider(value: value, in: range, step: 0.01)
                .tint(color)
        }
    }
}

// MARK: - 预览

/// 模拟一块 16:9 横屏，画出仪表关键元素，实时反映缩放/位移
struct DashLayoutPreview: View {

    let layout: DashLayout
    @ObservedObject var themeMgr: ThemeManager = .shared

    /// 模拟屏幕的宽高比（横屏 2796:1290 ≈ 2.17）
    private let screenRatio: CGFloat = 2.17
    /// 灵动岛占高度的比例
    private let islandRatio: CGFloat = 0.15
    /// 底部横条
    private let homeBarRatio: CGFloat = 0.05

    var body: some View {
        GeometryReader { geo in
            // 按 16:9 加黑边的方式放一块屏幕
            let w = geo.size.width
            let h = min(w / screenRatio, geo.size.height)
            let sw = h * screenRatio

            ZStack {
                // 屏幕轮廓
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(themeMgr.isLight ? 0.85 : 1.0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    }
                    .frame(width: sw, height: h)

                // 安全区（虚线）
                let insetTop = h * islandRatio
                let insetBottom = h * homeBarRatio
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.green.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: sw - 6, height: h - insetTop - insetBottom - 4)
                    .offset(y: (insetTop - insetBottom) / 2)

                // 灵动岛
                Capsule()
                    .fill(Color.black)
                    .frame(width: sw * 0.16, height: insetTop * 0.55)
                    .offset(y: -h / 2 + insetTop * 0.5)

                // 仪表内容（按缩放/位移画）
                previewContent(size: CGSize(width: sw, height: h))
                    // 只留安全区可见，超出部分被裁
                    .frame(width: sw, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // 底部横条
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: sw * 0.22, height: 3)
                    .offset(y: h / 2 - insetBottom * 0.6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// 仪表简化版内容
    private func previewContent(size: CGSize) -> some View {
        let sx = layout.safeScaleX
        let sy = layout.safeScaleY
        let ox = layout.safeShiftX * sx * 0.5
        let oy = layout.safeShiftY * sy * 0.5

        return VStack(spacing: 3) {
            // 顶栏
            HStack(spacing: 4) {
                bar(w: 34, h: 5, color: themeMgr.color(.warn))
                Spacer()
                bar(w: 20, h: 5, color: themeMgr.color(.rpm))
                bar(w: 14, h: 5, color: themeMgr.color(.power))
            }
            // 转速带
            RoundedRectangle(cornerRadius: 1)
                .fill(themeMgr.color(.rpm).opacity(0.4))
                .frame(height: 6)
            // 中间：速度 + 档位
            HStack {
                bar(w: 42, h: 14, color: themeMgr.color(.power))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(themeMgr.color(.power).opacity(0.6), lineWidth: 0.8)
                            .frame(width: 9, height: 9)
                    }
                }
                Spacer()
                bar(w: 16, h: 26, color: themeMgr.color(.voltage).opacity(0.7))
            }
            .padding(.vertical, 4)
            // 底部数据行
            HStack(spacing: 4) {
                ForEach(0..<6) { _ in
                    bar(w: 22, h: 5, color: themeMgr.color(.current).opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: size.width * 0.9, height: size.height * 0.86)
        .scaleEffect(x: sx, y: sy, anchor: .center)
        .offset(x: ox, y: oy)
    }

    private func bar(w: CGFloat, h: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: w, height: h)
    }
}
