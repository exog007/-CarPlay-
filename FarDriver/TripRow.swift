//
//  TripRow.swift
//  行程统计的单个账本行
//
//  四套账本各占一行，展开能看到里程 / 累计能量 / 百公里能耗 / 平均功率。
//  电摩显示「电耗」，OBD 显示「油耗」，单位自动跟着账本类型变。
//

import SwiftUI

struct TripRow: View {
    let ledger: TripLedger

    @ObservedObject var themeMgr: ThemeManager = .shared
    @ObservedObject private var trip = TripMeter.shared

    @State private var expanded = false

    /// 这个账本是不是当前数据源在用的
    private var isActive: Bool {
        TripLedger.current == ledger
    }

    private var snapshot: (distance: Double, energy: Double, seconds: Double) {
        trip.snapshot(ledger)
    }

    private var consumption: Double {
        trip.consumption(ledger)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── 标题行 ──
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: ledger.isElectric ? "bolt.car.fill" : "car.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(isActive
                                         ? themeMgr.color(.ok)
                                         : themeMgr.secondary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(ledger.title)
                            .font(.subheadline)
                            .foregroundStyle(themeMgr.foreground)
                        Text(String(format: "%.2f km · %@",
                                    snapshot.distance,
                                    consumption > 0
                                        ? String(format: "%.1f %@", consumption, ledger.consumptionUnit)
                                        : "无数据"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeMgr.secondary)
                    }

                    Spacer(minLength: 4)

                    if isActive {
                        Text("当前")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(themeMgr.color(.ok).opacity(0.18))
                            .foregroundStyle(themeMgr.color(.ok))
                            .clipShape(Capsule())
                    }

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── 展开详情 ──
            if expanded {
                VStack(spacing: 6) {
                    detailRow("小计里程",
                              String(format: "%.2f km", snapshot.distance),
                              .secondary)

                    detailRow(ledger.energyLabel,
                              String(format: "%.3f %@", snapshot.energy, ledger.energyUnit),
                              .secondary)

                    detailRow(ledger.consumptionLabel,
                              consumption > 0
                                  ? String(format: "%.1f %@", consumption, ledger.consumptionUnit)
                                  : "--",
                              themeMgr.color(.ok))

                    detailRow("平均功率",
                              avgPowerText,
                              .secondary)

                    detailRow("行车时间",
                              movingTimeText,
                              .secondary)

                    Button(role: .destructive) {
                        TripMeter.shared.reset(ledger)
                    } label: {
                        Label("清空这一项", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                }
                .padding(.leading, 30)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }

    private func detailRow(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(themeMgr.foreground)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var avgPowerText: String {
        let s = snapshot
        guard s.seconds > 1 else { return "--" }
        if ledger.isElectric {
            let w = s.energy * 1000.0 / (s.seconds / 3600.0)
            return String(format: "%.0f W", w)
        }
        // 油耗模式：按 1L ≈ 8.9kWh 折算等效功率
        let w = s.energy * 8.9 * 1000.0 / (s.seconds / 3600.0)
        return String(format: "%.0f W", w)
    }

    private var movingTimeText: String {
        let sec = Int(snapshot.seconds)
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        if h > 0 {
            return String(format: "%d时%d分", h, m)
        } else if m > 0 {
            return String(format: "%d分%d秒", m, s)
        } else {
            return String(format: "%d秒", s)
        }
    }
}
