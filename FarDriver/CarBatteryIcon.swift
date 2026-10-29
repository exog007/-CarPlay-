//
//  CarBatteryIcon.swift
//  汽车电瓶故障灯图标（纯 SwiftUI 绘制）
//
//  造型按真车仪表的标准蓄电池指示灯：
//    - 长方形外壳
//    - 顶部两个接线桩
//    - 内部左侧「−」负极横杠
//    - 内部右侧「+」正极十字
//
//  不用 SF Symbols，因为 Apple 的符号库里没有这个造型。
//

import SwiftUI

struct CarBatteryIcon: View {

    /// 尺寸（高度）
    var size: CGFloat = 15
    /// 颜色
    var color: Color = .yellow
    /// 线宽
    var lineWidth: CGFloat = 1.4

    var body: some View {
        Canvas { ctx, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            // 外壳在下面留出接线桩的空间
            let terminalH = h * 0.14
            let bodyTop = terminalH
            let bodyH = h - terminalH
            let bodyRect = CGRect(x: lineWidth / 2,
                                  y: bodyTop,
                                  width: w - lineWidth,
                                  height: bodyH - lineWidth / 2)

            let stroke = StrokeStyle(lineWidth: lineWidth,
                                     lineCap: .round,
                                     lineJoin: .round)

            // ① 两个接线桩
            let terminalW = w * 0.17
            let terminalR = CGRect(x: w * 0.18,
                                   y: 0,
                                   width: terminalW,
                                   height: terminalH + lineWidth * 0.6)
            let terminalL = CGRect(x: w - w * 0.18 - terminalW,
                                   y: 0,
                                   width: terminalW,
                                   height: terminalH + lineWidth * 0.6)
            for r in [terminalR, terminalL] {
                ctx.fill(Path(roundedRect: r, cornerRadius: lineWidth * 0.5),
                         with: .color(color))
            }

            // ② 外壳（圆角矩形描边）
            ctx.stroke(Path(roundedRect: bodyRect, cornerRadius: lineWidth * 1.2),
                       with: .color(color),
                       style: stroke)

            // ③ 内部符号区
            let innerPad = w * 0.16
            let symTop = bodyTop + bodyH * 0.22
            let symH = bodyH * 0.56

            // 负极横杠（左）
            let minusW = w * 0.26
            let minusX = innerPad
            let minusY = symTop + symH / 2
            var minus = Path()
            minus.move(to: CGPoint(x: minusX, y: minusY))
            minus.addLine(to: CGPoint(x: minusX + minusW, y: minusY))
            ctx.stroke(minus, with: .color(color), style: stroke)

            // 正极十字（右）
            let plusCx = w - innerPad - minusW / 2
            let plusCy = minusY
            let plusArmX = minusW / 2
            let plusArmY = symH / 2
            var plus = Path()
            // 横
            plus.move(to: CGPoint(x: plusCx - plusArmX, y: plusCy))
            plus.addLine(to: CGPoint(x: plusCx + plusArmX, y: plusCy))
            // 竖
            plus.move(to: CGPoint(x: plusCx, y: plusCy - plusArmY))
            plus.addLine(to: CGPoint(x: plusCx, y: plusCy + plusArmY))
            ctx.stroke(plus, with: .color(color), style: stroke)
        }
        .frame(width: size * 1.24, height: size)
    }
}

// MARK: - 便捷用法

extension CarBatteryIcon {
    /// 亮起样式（带发光）
    func lit(_ on: Bool, isOn onColor: Color, isOff offColor: Color) -> some View {
        ZStack {
            if on {
                // 光晕
                self
                    .opacity(0.55)
                    .blur(radius: 2.5)
            }
            self.opacity(on ? 1 : 0.16)
        }
        .foregroundStyle(on ? onColor : offColor)
    }
}
