import SwiftUI

/// Shared main-window colors. Dark values preserve the existing DictaFlow palette.
enum AppTheme {
    static let background = ThemeColor.adaptive(light: 0xF7F7F8, dark: 0x17191D)
    static let sidebar = ThemeColor.adaptive(light: 0xECEFF3, dark: 0x202A38)
    static let sidebarBorder = ThemeColor.adaptive(light: 0xD5D9DF, dark: 0x313A47)
    static let barFill = ThemeColor.adaptive(light: 0xF7F7F8, dark: 0x1C1E22)
    static let tileFill = ThemeColor.adaptive(light: 0xFFFFFF, dark: 0x23252A)
    static let controlFill = ThemeColor.adaptive(light: 0xE9EBEE, dark: 0x303237)
    static let editorFill = ThemeColor.adaptive(light: 0xF2F3F5, dark: 0x1F2125)
    static let accent = ThemeColor.adaptive(light: 0x3D63DB, dark: 0x4D78FB)
    static let modelActive = ThemeColor.adaptive(light: 0x247A43, dark: 0x46B471)
    static let warning = ThemeColor.adaptive(light: 0x976018, dark: 0xF0AB4F)
    static let destructive = ThemeColor.adaptive(light: 0xBE3042, dark: 0xD53C49)
    static let border = ThemeColor.adaptive(light: 0xDCDFE4, dark: 0x36383C)
    static let primaryText = ThemeColor.adaptive(light: 0x202124, dark: 0xF5F6F8)
    static let secondaryText = ThemeColor.adaptive(light: 0x636871, dark: 0x9499A3)
    static let tertiaryText = ThemeColor.adaptive(light: 0x6B707A, dark: 0x9298A3)
}
