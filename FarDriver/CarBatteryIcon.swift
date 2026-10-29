//
//  CarBatteryIcon.swift
//  汽车电瓶故障灯图标（纯 SwiftUI 绘制）
//
//  按参考图重画的标准蓄电池指示灯造型：
//    - 长方形外壳，大圆角，粗描边
//    - 顶部两个接线桩
//    - 内部左上「−」负极短横
//    - 内部右上「+」正极十字
//
//  不用 SF Symbols：Apple 符号库里没有这个造型的图标。
//

import SwiftUI

struct CarBatteryIcon: View {

    /// 颜色
    var color: Color = .yellow
    /// 描边粗细相对高度的比例
    var strokeRatio: CGFloat = 0.075

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lw = h * strokeRatio

            // 外壳：顶部留出接线桩高度
            let terminalH = h * 0.15
            let bodyRect = CGRect(
                x: lw / 2,
                y: terminalH,
                width: w - lw,
                height: h - terminalH - lw / 2
            )
            let corner = h * 0.13

            ZStack {
                // ① 两个接线桩（在外壳上面，被外壳盖住下沿）
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(color)
                        .frame(width: w * 0.13, height: terminalH + lw * 0.75)
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(color)
                        .frame(width: w * 0.13, height: terminalH + lw * 0.75)
                }
                .frame(width: w * 0.62)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // ② 外壳
                RoundedRectangle(cornerRadius: corner)
                    .stroke(color, lineWidth: lw)
                    .frame(width: bodyRect.width, height: bodyRect.height)
                    .offset(y: terminalH / 2)

                // ③ 内部符号
                // 负极「−」在左上，正极「+」在右上
                let symInsetX = w * 0.17
                let symTop = bodyRect.minY + bodyRect.height * 0.20
                let symH = bodyRect.height * 0.26
                let minusW = w * 0.14
                let plusArm = w * 0.085

                Canvas { ctx, _ in
                    let style = StrokeStyle(lineWidth: lw * 0.78,
                                            lineCap: .round,
                                            lineJoin: .round)

                    // 负极横杠
                    var minus = Path()
                    minus.move(to: CGPoint(x: symInsetX,
                                           y: symTop + symH / 2))
                    minus.addLine(to: CGPoint(x: symInsetX + minusW,
                                              y: symTop + symH / 2))
                    ctx.stroke(minus, with: .color(color), style: style)

                    // 正极十字
                    let cx = w - symInsetX - minusW / 2
                    let cy = symTop + symH / 2
                    var plus = Path()
                    plus.move(to: CGPoint(x: cx - plusArm, y: cy))
                    plus.addLine(to: CGPoint(x: cx + plusArm, y: cy))
                    plus.move(to: CGPoint(x: cx, y: cy - plusArm * 1.15))
                    plus.addLine(to: CGPoint(x: cx, y: cy + plusArm * 1.15))
                    ctx.stroke(plus, with: .color(color), style: style)
                }
                .frame(width: w, height: h)
            }
        }
        // 参考图宽高比 ≈ 134:104
        .aspectRatio(1.29, contentMode: .fit)
    }
}

// MARK: - 预览

#Preview {
    ZStack {
        Color.black
        HStack(spacing: 20) {
            CarBatteryIcon(color: Color(hex: "#F2A200"))
                .frame(height: 30)
            CarBatteryIcon(color: Color(hex: "#F2A200").opacity(0.16))
                .frame(height: 30)
        }
    }
}
