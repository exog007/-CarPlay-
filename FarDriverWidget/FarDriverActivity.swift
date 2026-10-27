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

// MARK: - 动态数据

struct FarDriverAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        var voltage: Double = 0
        var current: Double = 0
        var power: Double = 0
        var rpm: Double = 0
        var speed: Double = 0
        var gear: Int = 0
        var mosTemp: Int = 0
        var motorTemp: Int = 0
        var soc: Int = 0
        var isRegen: Bool = false
    }

    /// 静态数据：车名
    var deviceName: String
}

// MARK: - 工具

private func tempColor(_ t: Int, warnAt: Int) -> Color {
    t >= warnAt ? .red : .orange
}

// MARK: - 锁屏完整卡片（CarPlay 也用这个）

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<FarDriverAttributes>

    private var s: FarDriverAttributes.ContentState { context.state }

    var body: some View {
        HStack(spacing: 14) {
            // 左：转速大圆环
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(max(s.rpm / 8000, 0), 1))
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .blue, .cyan],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
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
                    dataCell(icon: "bolt.fill", value: "\(Int(s.power))", unit: "W", color: .orange)
                    dataCell(icon: "gauge.with.needle", value: "\(Int(s.speed))", unit: "km/h", color: .purple)
                }
                HStack(spacing: 12) {
                    dataCell(icon: "thermometer.medium", value: "\(s.mosTemp)°", unit: "", color: tempColor(s.mosTemp, warnAt: 75))
                    dataCell(icon: "engine.combustion", value: "\(s.motorTemp)°", unit: "", color: tempColor(s.motorTemp, warnAt: 110))
                }
                HStack(spacing: 12) {
                    dataCell(icon: "battery.75", value: String(format: "%.0f", s.voltage), unit: "V", color: .yellow)
                    dataCell(icon: "waveform.path", value: String(format: "%.0f", s.current), unit: "A", color: s.isRegen ? .green : .mint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private func dataCell(icon: String, value: String, unit: String, color: Color) -> some View {
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
            // 展开状态
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
                HStack(spacing: 20) {
                    tempBadge("MOS", s.mosTemp, warnAt: 75)
                    tempBadge("电机", s.motorTemp, warnAt: 110)
                    batteryBadge(s.voltage, s.current, s.isRegen)
                }
                .padding(.top, 4)
            }
        } compactLeading: {
            // 紧凑：转速
            HStack(spacing: 2) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10))
                    .foregroundStyle(.cyan)
                Text("\(Int(s.rpm))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        } compactTrailing: {
            // 紧凑：温度
            Text("\(s.mosTemp)°")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tempColor(s.mosTemp, warnAt: 75))
        } minimal: {
            Image(systemName: "bolt.car.fill")
                .font(.system(size: 12))
                .foregroundStyle(.cyan)
        }
        .widgetURL(URL(string: "fardriver://open"))
    }

    private func tempBadge(_ label: String, _ value: Int, warnAt: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text("\(value)°")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tempColor(value, warnAt: warnAt))
        }
    }

    private func batteryBadge(_ v: Double, _ a: Double, _ regen: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "battery.75")
                .font(.system(size: 9))
                .foregroundStyle(.yellow.opacity(0.8))
            Text(String(format: "%.0f", v))
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
}

// MARK: - Widget 注册

struct FarDriverLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FarDriverAttributes.self) { context in
            // 锁屏 / CarPlay 用这个
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
        SimpleWidgetEntry(date: Date(), data: .empty)
    }
    func getSnapshot(in context: Context, completion: @escaping (SimpleWidgetEntry) -> Void) {
        completion(SimpleWidgetEntry(date: Date(), data: SharedStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleWidgetEntry>) -> Void) {
        let e = SimpleWidgetEntry(date: Date(), data: SharedStore.load())
        let next = Calendar.current.date(byAdding: .second, value: 60, to: Date())!
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
