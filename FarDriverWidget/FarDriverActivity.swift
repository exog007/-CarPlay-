//
//  FarDriverActivity.swift
//  Live Activity —— CarPlay 显示
//
//  先做最简版本，确保能编译，再逐步加回细节
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - 工具

func tempColor(_ t: Int, warnAt: Int) -> Color {
    if t >= warnAt {
        return Color.red
    }
    return Color.orange
}

// MARK: - 锁屏 / CarPlay 卡片

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<FarDriverAttributes>

    var body: some View {
        let s = context.state
        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(max(s.rpm / 8000, 0), 1))
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("\(Int(s.rpm))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                    Text("rpm")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    CellView(icon: "gauge.with.needle", value: "\(Int(s.rpm))", unit: "rpm", color: Color.cyan)
                    CellView(icon: "bolt.fill", value: "\(Int(s.power))", unit: "W", color: Color.orange)
                }
                HStack(spacing: 12) {
                    CellView(icon: "thermometer.medium", value: "\(s.mosTemp)°", unit: "", color: tempColor(s.mosTemp, warnAt: 60))
                    CellView(icon: "engine.combustion", value: "\(s.motorTemp)°", unit: "", color: tempColor(s.motorTemp, warnAt: 50))
                }
                HStack(spacing: 12) {
                    CellView(icon: "battery.75", value: String(format: "%.0f", s.voltage), unit: "V", color: Color.yellow)
                    CellView(icon: "waveform.path", value: String(format: "%.0f", s.current), unit: "A", color: Color.mint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}

// MARK: - 小数据单元

struct CellView: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color.opacity(0.8))
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 8))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }
}

// MARK: - 灵动岛（直接写在 ActivityConfiguration 里，不包装成 View）

// MARK: - 灵动岛展开底栏

struct ExpandedBottomRow: View {
    let mosTemp: Int
    let motorTemp: Int
    let voltage: Double
    let regen: Bool

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 3) {
                Text("MOS")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
                Text("\(mosTemp)°")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tempColor(mosTemp, warnAt: 60))
            }
            HStack(spacing: 3) {
                Text("电机")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
                Text("\(motorTemp)°")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tempColor(motorTemp, warnAt: 50))
            }
            HStack(spacing: 3) {
                Image(systemName: "battery.75")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.yellow.opacity(0.8))
                Text(String(format: "%.0f", voltage))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.yellow)
                Text("V")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Widget 注册

struct FarDriverLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FarDriverAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开：只显示电压 + MOS 温度，大字号
                DynamicIslandExpandedRegion(.leading) {
                    VStack(spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "battery.75")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.yellow.opacity(0.9))
                            Text(String(format: "%.1f", context.state.voltage))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.yellow)
                            Text("V")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                        }
                        Text("电压")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "thermometer.medium")
                                .font(.system(size: 12))
                                .foregroundStyle(tempColor(context.state.mosTemp, warnAt: 60).opacity(0.9))
                            Text("\(context.state.mosTemp)")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(tempColor(context.state.mosTemp, warnAt: 60))
                            Text("°C")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                            if context.state.mosTemp > 60 {
                                TriangleWarningIcon(size: 14)
                            }
                        }
                        Text("MOS 温度")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.trailing, 4)
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    Image(systemName: "battery.75")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.yellow)
                    Text(String(format: "%.0f", context.state.voltage))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.yellow)
                }
            } compactTrailing: {
                HStack(spacing: 1) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 9))
                        .foregroundStyle(tempColor(context.state.mosTemp, warnAt: 60))
                    Text("\(context.state.mosTemp)°")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tempColor(context.state.mosTemp, warnAt: 60))
                }
            } minimal: {
                Image(systemName: "bolt.car.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.cyan)
            }
        }
    }
}

// MARK: - Widget Bundle

@main
struct FarDriverWidgetBundle: WidgetBundle {
    var body: some Widget {
        FarDriverLiveActivity()
        FarDriverSimpleWidget()
    }
}

// MARK: - 普通小组件

struct SimpleWidgetEntry: TimelineEntry {
    let date: Date
    let data: ControllerData?
}

struct SimpleProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleWidgetEntry {
        SimpleWidgetEntry(date: Date(), data: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (SimpleWidgetEntry) -> Void) {
        completion(SimpleWidgetEntry(date: Date(), data: SharedStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleWidgetEntry>) -> Void) {
        let e = SimpleWidgetEntry(date: Date(), data: SharedStore.load())
        let next = Calendar.current.date(byAdding: .second, value: 60, to: Date()) ?? Date()
        completion(Timeline(entries: [e], policy: .after(next)))
    }
}

struct FarDriverSimpleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FarDriverSimpleWidget", provider: SimpleProvider()) { entry in
            SimpleWidgetView(data: entry.data)
        }
        .configurationDisplayName("远驱控制器")
        .description("显示转速、功率、温度")
        .supportedFamilies([.systemSmall])
    }
}

struct SimpleWidgetView: View {
    let data: ControllerData?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "bolt.car.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cyan)
                Text("远驱")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            if let d = data {
                Text("\(Int(d.rpm))")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.cyan)
                HStack(spacing: 6) {
                    Text("\(Int(d.power))W")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                    Text("\(d.mosTemp)°")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                }
            } else {
                Text("未连接")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(10)
        .containerBackground(for: .widget) {
            Color(white: 0.08)
        }
    }
}
