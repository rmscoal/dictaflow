import SwiftUI

/// Ember's semantic sRGB colors, shared by windows, menus, and transient panels.
enum AppTheme {
    static let background = ThemeColor.adaptive(light: 0xF3F0E9, dark: 0x171816)
    static let sidebar = ThemeColor.adaptive(light: 0xE9E4D8, dark: 0x262722)
    static let glass = ThemeColor.adaptive(light: 0xF9F5EC, dark: 0x2D2E28)
    static let sidebarBorder = border
    static let barFill = background
    static let tileFill = ThemeColor.adaptive(light: 0xFFFDF8, dark: 0x242521)
    static let controlFill = ThemeColor.adaptive(light: 0xEAE6DC, dark: 0x2E3029)
    static let editorFill = tileFill
    static let accent = ThemeColor.adaptive(light: 0x785422, dark: 0xE6BE83)
    static let selectedFill = ThemeColor.adaptive(light: 0xE8DDCA, dark: 0x393226)
    static let actionFill = ThemeColor.adaptive(light: 0x765126, dark: 0xE6BE83)
    static let actionText = ThemeColor.adaptive(light: 0xFFFAF0, dark: 0x27251F)
    static let modelActive = ThemeColor.adaptive(light: 0x426745, dark: 0xB3C7A7)
    static let warning = ThemeColor.adaptive(light: 0x85510C, dark: 0xE6BE83)
    static let destructive = ThemeColor.adaptive(light: 0xAD3B38, dark: 0xF2A6A2)
    static let border = ThemeColor.adaptive(light: 0xD8D4C8, dark: 0x414239)
    static let primaryText = ThemeColor.adaptive(light: 0x2F322B, dark: 0xF0EDE5)
    static let secondaryText = ThemeColor.adaptive(light: 0x66695F, dark: 0xB6B4A8)
    static let tertiaryText = secondaryText
    static let paper = ThemeColor.adaptive(light: 0xEAE1CF, dark: 0x34352E)
    static let paperBorder = ThemeColor.adaptive(light: 0xCFC3AD, dark: 0x535447)
    static let paperText = ThemeColor.adaptive(light: 0x37392F, dark: 0xF4EDDD)
    static let paperSecondaryText = ThemeColor.adaptive(light: 0x626354, dark: 0xC3BFAE)
    static let errorFill = ThemeColor.adaptive(light: 0xF7E6E2, dark: 0x392824)
    static let errorBorder = ThemeColor.adaptive(light: 0xD5A49A, dark: 0x81514A)
    static let errorText = ThemeColor.adaptive(light: 0x8E3029, dark: 0xF0B6AA)
}
