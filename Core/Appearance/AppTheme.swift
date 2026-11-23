import SwiftUI

/// Semantic colors for Omdo's monochrome surfaces and controls.
enum AppTheme {
    static let windowBackgroundColor = ThemeColor.adaptiveNSColor(light: 0xFAFAFA, dark: 0x151515)
    static let background = Color(nsColor: windowBackgroundColor)
    static let sidebar = ThemeColor.adaptive(light: 0xF2F2F2, dark: 0x1D1D1D)
    static let glass = ThemeColor.adaptive(light: 0xFFFFFF, dark: 0x252525)
    static let tileFill = glass
    static let controlFill = ThemeColor.adaptive(light: 0xE4E4E4, dark: 0x161616)
    static let opaqueControlFill = ThemeColor.adaptive(light: 0xE4E4E4, dark: 0x343434)
    static let editorFill = tileFill
    static let accent = ThemeColor.adaptive(light: 0x242424, dark: 0xF5F5F5)
    static let selectedFill = ThemeColor.adaptive(light: 0xDCDCDC, dark: 0x484848)
    static let actionFill = ThemeColor.adaptive(light: 0x252525, dark: 0xEEEEEE)
    static let actionText = ThemeColor.adaptive(light: 0xFFFFFF, dark: 0x161616)
    static let ready = ThemeColor.adaptive(light: 0x17673B, dark: 0x4ADE80)
    static let modelActive = primaryText
    static let warning = ThemeColor.adaptive(light: 0xA84B00, dark: 0xFFAA55)
    static let destructive = ThemeColor.adaptive(light: 0xA32828, dark: 0xFFA9A9)
    static let border = ThemeColor.adaptive(light: 0xB0B0B0, dark: 0x5D5D5D)
    static let primaryText = ThemeColor.adaptive(light: 0x161616, dark: 0xF8F8F8)
    static let secondaryText = ThemeColor.adaptive(light: 0x3D3D3D, dark: 0xC5C5C5)
    static let tertiaryText = secondaryText
    static let paper = glass
    static let paperBorder = border
    static let paperText = primaryText
    static let paperSecondaryText = secondaryText
    static let brandTile = ThemeColor.adaptive(light: 0xF9F9F9, dark: 0x363636)
    static let brandPrimary = primaryText
    static let errorFill = ThemeColor.adaptive(light: 0xFFF2F2, dark: 0x352424)
    static let errorBorder = ThemeColor.adaptive(light: 0xD8AAAA, dark: 0x845454)
    static let errorText = ThemeColor.adaptive(light: 0x832626, dark: 0xFFBEBE)
}
