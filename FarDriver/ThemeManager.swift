//
//  ThemeManager.swift
//  全局主题状态（改了立刻生效）
//

import SwiftUI
import Combine

final class ThemeManager: ObservableObject {

    static let shared = ThemeManager()

    @Published var theme: AppTheme {
        didSet {
            theme.save()
        }
    }

    /// 缓存解码后的图片，避免每次刷新都重新读盘
    @Published private(set) var photoImage: UIImage?

    private init() {
        theme = AppTheme.load()
        reloadPhoto()
    }

    /// 重新从磁盘读背景图
    func reloadPhoto() {
        photoImage = BackgroundImageStore.load()
    }

    /// 换一张背景图并切到图片模式
    /// - Returns: 是否成功
    @discardableResult
    func setBackgroundPhoto(_ image: UIImage) -> Bool {
        guard BackgroundImageStore.save(image) else { return false }
        reloadPhoto()
        theme.backgroundType = .photo
        return true
    }

    /// 删掉背景图，退回预设主题
    func clearBackgroundPhoto() {
        BackgroundImageStore.delete()
        photoImage = nil
        theme.photoFileName = ""
        if theme.backgroundType == .photo {
            theme.backgroundType = .preset
        }
    }

    // MARK: - 背景

    var backgroundView: AnyView {
        AnyView(themeBackground)
    }

    @ViewBuilder
    private var themeBackground: some View {
        switch theme.backgroundType {
        case .solid:
            Color(hex: theme.solidHex)
                .ignoresSafeArea()

        case .gradient:
            LinearGradient(
                colors: [Color(hex: theme.gradientStart), Color(hex: theme.gradientEnd)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

        case .preset:
            let p = ThemePresets.all.first(where: { $0.id == theme.presetId }) ?? ThemePresets.all[0]
            LinearGradient(
                colors: [Color(hex: p.start), Color(hex: p.end)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

        case .photo:
            if let img = photoImage {
                GeometryReader { geo in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: theme.photoBlur)
                        .overlay {
                            Color.black.opacity(theme.photoDim)
                        }
                }
                .ignoresSafeArea()
            } else {
                // 没图了兜底
                LinearGradient(
                    colors: [Color(hex: "#0F0F12"), Color(hex: "#050507")],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - 常用色

    func color(_ slot: ColorSlot) -> Color { theme.color(for: slot) }
    var foreground: Color { theme.foreground }
    var secondary: Color { theme.secondaryForeground }
    var cardBG: Color { theme.cardBackground }
    var cardStroke: Color { theme.cardStroke }
    var isLight: Bool { theme.isLightBackground }

    // MARK: - 操作

    func reset() {
        theme = AppTheme()
    }

    func resetColors() {
        theme.resetColors()
    }
}
