//
//  FarDriverActivity.swift
//  Live Activity —— CarPlay 显示的核心
//
//  苹果官方文档：Live Activities display on the Lock Screen, in the Dynamic Island,
//  **in CarPlay**, and on a paired Mac or Apple Watch.
//
//  关键：Live Activity 不需要 CarPlay entitlement，iOS 会自动推到 CarPlay
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - 工具

func tempColor(_ t: Int, warnAt: Int) -> Color {
    return t >= warnAt ? Color.red : Color.orange
}

// MARK: - 锁屏完整卡片（CarPlay 也用这个）

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<FarDriverAttributes>

    private var s: FarDriverAttributes.ContentState { context.state }

    var body: some View {
        HStack(spacing: 14) {
            // 左：转速圆环
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
                        .foregroundStyle(.white)
                    Text("rpm")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 84, height: 84)

            // 右：数据网格
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    CellView(icon: "bolt.fill", value: "\(Int(s.power))", unit: "W", color: .orange)
                    CellView(icon: "gauge.with.needle", value: "\(Int(s.speed))", unit: "km/h", color: .purple)
                }
                HStack(spacing: 12) {
                    CellView(icon: "thermometer.medium", value: "\(s.mosTemp)°", unit: "", color: tempColor(s.mosTemp, warnAt: 75))
                    CellView(icon: "engine.combustion", value: "\(s.motorTemp)°", unit: "", color: tempColor(s.motorTemp, warnAt: 110))
                }
                HStack(spacing: 12) {
                    CellView(icon: "battery.75", value: String(format: "%.0f", s.voltage), unit: "V", color: .yellow)
                    CellView(icon: "waveform.path", value: String(format: "%.0f", s.current), unit: "A", color: s.isRegen ? .green : .mint)
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
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - 灵动岛

struct DynamicIslandView: View {
    let context: ActivityViewContext<FarDriverAttributes>

    private var s: FarDriverAttributes.ContentState { context.state }

    var body: some View {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                VStack(spacing: 1) {
                    Text("\(Int(s.rpm))")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("RPM")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            DynamicIslandExpandedRegion(.trailing) {
                VStack(spacing: 1) {
                    Text("\(Int(s.speed))")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.purple)
                    Text("KM/H")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            DynamicIslandExpandedRegion(.center) {
                VStack(spacing: 2) {
                    Text("\(Int(s.power))W")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                    Text("档位 \(s.gear)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                ExpandedBottomRow(mosTemp: s.mosTemp,
                                  motorTemp: s.motorTemp,
                                  voltage: s.voltage,
                                  regen: s.isRegen)
            }
        } compactLeading: {
            HStack(spacing: 2) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10))
                    .foregroundStyle(.cyan)
                Text("\(Int(s.rpm))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        } compactTrailing: {
            Text("\(s.mosTemp)°")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tempColor(s.mosTemp, warnAt: 75))
        } minimal: {
            Image(systemName: "bolt.car.fill")
                .font(.system(size: 12))
                .foregroundStyle(.cyan)
        }
    }
}

// 灵动岛展开底栏（独立结构体，避免类型推导问题）
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
                    .foregroundStyle(.secondary)
                Text("\(mosTemp)°")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tempColor(mosTemp, warnAt: 75))
            }
            HStack(spacing: 3) {
                Text("电机")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("\(motorTemp)°")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tempColor(motorTemp, warnAt: 110))
            }
            HStack(spacing: 3) {
                Image(systemName: "battery.75")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow.opacity(0.8))
                Text(String(format: "%.0f", voltage))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.yellow)
                Text("V")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                if regen {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
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
                .activityBackgroundTint(Color(red: 0.06, green: 0.08, blue: 0.12))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIslandView(context: context)
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

// MARK: - 普通小组件（备选，iPhone 桌面用）

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
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "bolt.car.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.cyan)
                    Text("远驱")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                if let d = entry.data {
                    Text("\(Int(d.rpm))")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.cyan)
                    HStack(spacing: 6) {
                        Text("\(Int(d.power))W")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("\(d.mosTemp)°")
                            .font(.system(size: 10))
                            .foregroundStyle(d.mosTemp > 75 ? .red : .orange)
                    }
                } else {
                    Text("未连接")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .containerBackground(for: .widget) { Color(white: 0.08) }
        }
        .configurationDisplayName("远驱控制器")
        .description("显示转速、功率、温度")
        .supportedFamilies([.systemSmall])
    }
}
