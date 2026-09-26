import SwiftUI

/// Reference surface colours stay neutral instead of inheriting desktop wallpaper tint.
/// Text, accents, controls and Liquid Glass continue to use the system appearance.
enum AppSurface: ShapeStyle {
    case window, raised, recessed, card, sheet, sidebar, agentBubble, userBubble

    func resolve(in environment: EnvironmentValues) -> Color {
        let dark = environment.colorScheme == .dark
        let rgb: UInt32 = switch self {
        case .window: dark ? 0x1E1E1E : 0xFFFFFF
        case .raised: dark ? 0x232325 : 0xFBFBFC
        case .recessed: dark ? 0x141416 : 0xF5F5F7
        case .card: dark ? 0x2C2C2F : 0xFFFFFF
        case .sheet: dark ? 0x2C2C2F : 0xF7F7F9
        case .sidebar: dark ? 0x232325 : 0xF3F3F7
        case .agentBubble: dark ? 0x262626 : 0xEEEEEE
        case .userBubble: dark ? 0x595959 : 0x080808
        }
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}
