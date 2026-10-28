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

    private init() {
        theme = AppTheme.load()
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
