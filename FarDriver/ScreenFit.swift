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

    /// 参考画布尺寸：按 iPhone 横屏的逻辑尺寸设计（852×393 = iPhone 15 横屏）
    ///
    /// ⚠️ 这里必须是「手机实际逻辑尺寸」，不能用参考图那种 1904 像素。
    /// 用 1904 会导致缩放系数只有 0.45，整个仪表被缩小一半，看着完全不对。
    static let refWidth: CGFloat = 852
    static let refHeight: CGFloat = 393

    /// 按实际屏幕算缩放比
    ///
    /// 手机横屏普遍在 393~430 高度之间，算出来约 1.0~1.1，几乎不缩放；
    /// 平板/大屏才会放大。下限锁 1.0，保证小屏手机上不会被缩小。
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 1, size.height > 1 else { return 1 }
        let s = min(size.width / refWidth, size.height / refHeight)
        return min(max(s, 1.0), 1.9)
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
