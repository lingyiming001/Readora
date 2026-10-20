import ReadoraCore
import AppKit
public enum ReaderTypography {
    public static func font(_ preferences: ReadingPreferences, heading: Bool = false) -> NSFont {
        let size = preferences.fontSize + (heading ? 5 : 0)
        let base = NSFont.systemFont(ofSize: size, weight: heading ? .semibold : .regular)
        switch preferences.font {
        case .songti: return NSFont(name: heading ? "Songti SC Bold" : "Songti SC", size: size) ?? base
        case .pingfang: return NSFont(name: heading ? "PingFang SC Semibold" : "PingFang SC", size: size) ?? base
        case .serif: return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .rounded: return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
    }
    public static func attributes(_ preferences: ReadingPreferences, heading: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = preferences.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font(preferences, heading: heading), .paragraphStyle: paragraph,
                .foregroundColor: textColor(preferences.theme)]
    }
    public static func background(_ theme: ReaderTheme) -> NSColor {
        switch theme {
        case .paper: color(0xFFFFFF)
        case .parchment: color(0xEFE4CF)
        case .sage: color(0xE6EBDD)
        case .night: color(0x20211F)
        }
    }
    public static func textColor(_ theme: ReaderTheme) -> NSColor { theme == .night ? color(0xE5E2D9) : color(0x171717) }
    public static func highlight(_ color: HighlightColor, theme: ReaderTheme) -> NSColor {
        let hex: UInt32 = switch color { case .gold: 0xEBC66A; case .mint: 0x85B79D; case .rose: 0xD99DAA }
        return Self.color(hex).withAlphaComponent(theme == .night ? 0.38 : 0.42)
    }
    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }
}
