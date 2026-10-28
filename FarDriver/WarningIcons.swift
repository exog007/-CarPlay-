//
//  WarningIcons.swift
//  温度警示图标
//
//  ⚠️ 这个文件必须同时加入【主 App】和【Widget Extension】两个 target
//

import SwiftUI

/// 红色三角形 + 白色感叹号（MOS 超温）
struct TriangleWarningIcon: View {
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            TriangleShape()
                .fill(Color.red)
            Text("!")
                .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .offset(y: size * 0.10)
        }
        .frame(width: size, height: size)
    }
}

/// 等边三角形
struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 黄色水温 / 发动机故障灯（电机超温）
struct EngineWarningIcon: View {
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.yellow, lineWidth: size * 0.09)
            EngineGlyph()
                .stroke(Color.yellow,
                        style: StrokeStyle(lineWidth: size * 0.11,
                                           lineCap: .round,
                                           lineJoin: .round))
                .padding(size * 0.22)
        }
        .frame(width: size, height: size)
    }
}

/// 简化的发动机轮廓
struct EngineGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // 顶部凸起（气缸盖）
        p.move(to: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.28))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.32, y: rect.minY + h * 0.28))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.06))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.60, y: rect.minY + h * 0.06))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.68, y: rect.minY + h * 0.28))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.82, y: rect.minY + h * 0.28))

        // 右侧
        p.move(to: CGPoint(x: rect.minX + w * 0.82, y: rect.minY + h * 0.28))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.82, y: rect.minY + h * 0.72))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.72))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.28))

        // 底部两条腿
        p.move(to: CGPoint(x: rect.minX + w * 0.34, y: rect.minY + h * 0.72))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.34, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + w * 0.66, y: rect.minY + h * 0.72))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.66, y: rect.maxY))

        return p
    }
}
