//
//  ScreenFit.swift
//  屏幕尺寸自动适配
//
//  思路：所有仪表按一个「参考画布」排版（1904×878，和参考图一致），
//  运行时按真实屏幕算出缩放比，整体等比缩放。
//  这样 iPhone / iPad / 不同分辨率都能保持同样的视觉比例，不会有的元素太大有的太小。
//

import SwiftUI

enum ScreenFit {

    /// 参考画布尺寸（横屏）
    static let refWidth: CGFloat = 1904
    static let refHeight: CGFloat = 878

    /// 按实际屏幕算缩放比
    ///
    /// - Parameter size: 实际可用区域尺寸
    /// - Returns: 缩放比，限制在 0.55 ~ 1.9 之间，避免极端机型上过大/过小
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 1, size.height > 1 else { return 1 }
        let sx = size.width / refWidth
        let sy = size.height / refHeight
        // 取小的那个，保证内容完整放得下
        let s = min(sx, sy)
        return min(max(s, 0.55), 1.9)
    }

    /// 竖屏参考画布（标准界面用）
    static let portraitRefWidth: CGFloat = 430
    static let portraitRefHeight: CGFloat = 932

    static func portraitScale(for size: CGSize) -> CGFloat {
        guard size.width > 1, size.height > 1 else { return 1 }
        let s = min(size.width / portraitRefWidth, size.height / portraitRefHeight)
        return min(max(s, 0.8), 1.6)
    }
}

/// 把内容按参考画布排版，再整体缩放到实际屏幕
struct FitToScreen<Content: View>: View {

    /// 参考画布尺寸
    var reference: CGSize = CGSize(width: ScreenFit.refWidth, height: ScreenFit.refHeight)
    /// 是否忽略安全区
    var ignoresSafeArea: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let s = ScreenFit.scale(for: geo.size)
            content()
                .frame(width: reference.width, height: reference.height)
                .scaleEffect(s, anchor: .center)
                // 缩放后容器仍占满整屏，内容居中
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(ignoresSafeArea ? .all : [])
    }
}
