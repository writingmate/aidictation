import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Design System

// Minimal design system using standard macOS colors
// Primary/Accent color is set via AccentColor.colorset in Assets

private extension Color {
    static var dsSystemBackground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #endif
    }

    static var dsSystemForeground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .labelColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .label)
        #endif
    }

    static var dsSystemSecondaryForeground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .secondaryLabelColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .secondaryLabel)
        #endif
    }

    static var dsSystemSeparator: Color {
        #if canImport(AppKit)
        return Color(nsColor: .separatorColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .separator)
        #endif
    }

    static var dsSystemControlBackground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .controlBackgroundColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var dsSystemMutedBackground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .tertiarySystemFill)
        #endif
    }

    static var dsSystemTextBackground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .textBackgroundColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #endif
    }
}

// MARK: - Button Styles

/// Primary button with brand accent background
public struct DSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(.title3)
            .foregroundStyle(Color.dsPrimaryForeground)
            .background(Capsule().fill(Color.dsPrimary))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Secondary button with border
public struct DSSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(.bodyMedium)
            .foregroundStyle(Color.dsSystemSecondaryForeground)
            .background(Capsule().stroke(Color.dsSystemSeparator, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Corner Radius Constants

public enum DSCornerRadius {
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let extraLarge: CGFloat = 24
}

// MARK: - Font Names

public enum DSFontName {
    public static let geist = "Geist"
    public static let geistMono = "GeistMono"
    public static let jetBrainsMono = "JetBrainsMono"
}

// MARK: - Typography

public enum DSTypography {
    // Matches macOS system font sizes
    case iconLarge // 64pt - for large icons/display
    case largeTitle // 26pt bold - .largeTitle
    case title // 22pt bold - .title
    case title2 // 17pt bold - .title2
    case title3 // 15pt semibold - .title3
    case headline // 13pt semibold - .headline
    case subheadline // 11pt regular - .subheadline
    case body // 13pt regular - .body
    case callout // 12pt regular - .callout
    case footnote // 10pt regular - .footnote
    case caption // 10pt regular - .caption
    case caption2 // 10pt regular - .caption2

    // Custom styles
    case h1 // 48pt bold
    case h2 // 36pt bold
    case h3 // 28pt bold
    case h4 // 22pt semibold
    case h5 // 17pt semibold
    case bodyMedium // 13pt medium
    case bodySemibold // 13pt semibold
    case captionMedium // 10pt medium
    case captionSemibold // 10pt semibold
    case label // 11pt regular
    case labelMedium // 11pt medium
    case small // 10pt regular
    case smallMedium // 10pt medium
    case tiny // 11pt regular
    case tinyBold // 11pt bold
    case micro // 9pt regular
    case microBold // 9pt bold

    // Monospace (JetBrains Mono)
    case mono // 13pt mono
    case monoSmall // 11pt mono

    public var font: Font {
        switch self {
        // System-matching sizes
        case .iconLarge: return DSFont.font(size: 64, weight: .regular)
        case .largeTitle: return DSFont.font(size: 26, weight: .bold)
        case .title: return DSFont.font(size: 22, weight: .bold)
        case .title2: return DSFont.font(size: 17, weight: .bold)
        case .title3: return DSFont.font(size: 15, weight: .semibold)
        case .headline: return DSFont.font(size: 13, weight: .semibold)
        case .subheadline: return DSFont.font(size: 11, weight: .regular)
        case .body: return DSFont.font(size: 13, weight: .regular)
        case .callout: return DSFont.font(size: 12, weight: .regular)
        case .footnote: return DSFont.font(size: 10, weight: .regular)
        case .caption: return DSFont.font(size: 10, weight: .regular)
        case .caption2: return DSFont.font(size: 10, weight: .regular)
        // Custom sizes
        case .h1: return DSFont.font(size: 48, weight: .bold)
        case .h2: return DSFont.font(size: 36, weight: .bold)
        case .h3: return DSFont.font(size: 28, weight: .bold)
        case .h4: return DSFont.font(size: 22, weight: .semibold)
        case .h5: return DSFont.font(size: 17, weight: .semibold)
        case .bodyMedium: return DSFont.font(size: 13, weight: .medium)
        case .bodySemibold: return DSFont.font(size: 13, weight: .semibold)
        case .captionMedium: return DSFont.font(size: 10, weight: .medium)
        case .captionSemibold: return DSFont.font(size: 10, weight: .semibold)
        case .label: return DSFont.font(size: 11, weight: .regular)
        case .labelMedium: return DSFont.font(size: 11, weight: .medium)
        case .small: return DSFont.font(size: 10, weight: .regular)
        case .smallMedium: return DSFont.font(size: 10, weight: .medium)
        case .tiny: return DSFont.font(size: 11, weight: .regular)
        case .tinyBold: return DSFont.font(size: 11, weight: .bold)
        case .micro: return DSFont.font(size: 9, weight: .regular)
        case .microBold: return DSFont.font(size: 9, weight: .bold)
        case .mono: return DSFont.monoFont(size: 13, weight: .regular)
        case .monoSmall: return DSFont.monoFont(size: 11, weight: .regular)
        }
    }
}

// MARK: - Font Helper

public enum DSFont {
    /// Returns system font
    public static func font(size: CGFloat, weight: Font.Weight) -> Font {
        return .system(size: size, weight: weight)
    }

    /// Returns system monospace font
    public static func monoFont(size: CGFloat, weight: Font.Weight) -> Font {
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Font Extension for easy replacement of .system()

public extension Font {
    /// System font - alias for consistency
    static func geist(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .system(size: size, weight: weight)
    }

    /// System monospace font
    static func jetBrainsMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

public extension View {
    func dsFont(_ style: DSTypography) -> some View {
        font(style.font)
    }
}

// MARK: - Shadow

public enum DSShadow {
    case soft, medium

    public var radius: CGFloat {
        switch self {
        case .soft: return 4
        case .medium: return 8
        }
    }

    public var opacity: Double {
        switch self {
        case .soft: return 0.05
        case .medium: return 0.1
        }
    }

    public var y: CGFloat {
        switch self {
        case .soft: return 2
        case .medium: return 4
        }
    }
}

public extension View {
    func dsShadow(_ style: DSShadow) -> some View {
        shadow(color: Color.black.opacity(style.opacity), radius: style.radius, y: style.y)
    }
}

// MARK: - Color Palette

// Default SwiftUI colors with brand accent

public extension Color {
    // Background & Foreground - use system colors
    static var dsBackground: Color { dsSystemBackground }
    static var dsForeground: Color { dsSystemForeground }

    // Primary brand accent. Keep code-defined so app extensions do not depend on host asset lookup.
    static var dsPrimary: Color { Color(red: 1.0, green: 0.3882352941, blue: 0.0) }
    static var dsPrimaryForeground: Color { .white }

    // Secondary - use system secondary
    static var dsSecondary: Color { dsSystemSecondaryForeground }
    static var dsSecondaryForeground: Color { .white }

    // Accent
    static var dsAccent: Color { dsPrimary }
    static var dsAccentForeground: Color { dsSystemForeground }

    // Card - use system control background
    static var dsCard: Color { dsSystemControlBackground }
    static var dsCardForeground: Color { dsSystemForeground }

    // Popover - use system popover background
    static var dsPopover: Color { dsSystemControlBackground }
    static var dsPopoverForeground: Color { dsSystemForeground }

    // Muted - use system colors
    static var dsMuted: Color { dsSystemMutedBackground }
    static var dsMutedForeground: Color { dsSystemSecondaryForeground }

    // Border, Input, Ring - use system colors
    static var dsBorder: Color { dsSystemSeparator }
    static var dsInput: Color { dsSystemTextBackground }
    static var dsRing: Color { dsPrimary }

    // Destructive
    static var dsDestructive: Color { .red }
    static var dsDestructiveForeground: Color { .white }

    // Sidebar - use system sidebar colors
    static var dsSidebarBackground: Color { dsSystemControlBackground }
    static var dsSidebarForeground: Color { dsSystemForeground }
    static var dsSidebarPrimary: Color { .orange }
    static var dsSidebarPrimaryForeground: Color { .white }
    static var dsSidebarAccent: Color { .orange }
    static var dsSidebarAccentForeground: Color { .white }
    static var dsSidebarBorder: Color { dsSystemSeparator }
    static var dsSidebarRing: Color { .orange }

    // Charts - use standard SwiftUI colors
    static var dsChart1: Color { .orange }
    static var dsChart2: Color { .blue }
    static var dsChart3: Color { .green }
    static var dsChart4: Color { .purple }
    static var dsChart5: Color { .pink }

    // Legacy adaptive functions - now just return the adaptive system colors
    static func dsBackgroundAdaptive(for _: ColorScheme) -> Color { dsBackground }
    static func dsForegroundAdaptive(for _: ColorScheme) -> Color { dsForeground }
    static func dsPrimaryAdaptive(for _: ColorScheme) -> Color { dsPrimary }
    static func dsPrimaryGlowAdaptive(for _: ColorScheme) -> Color { dsPrimary }
    static func dsSecondaryAdaptive(for _: ColorScheme) -> Color { dsSecondary }
    static func dsAccentAdaptive(for _: ColorScheme) -> Color { dsAccent }
    static func dsMutedAdaptive(for _: ColorScheme) -> Color { dsMuted }
    static func dsMutedForegroundAdaptive(for _: ColorScheme) -> Color { dsMutedForeground }
    static func dsBorderAdaptive(for _: ColorScheme) -> Color { dsBorder }
    static func dsCardAdaptive(for _: ColorScheme) -> Color { dsCard }
}

// MARK: - View Modifiers

public struct DSCardStyle: ViewModifier {
    public var cornerRadius: CGFloat = 12
    public var hasShadow: Bool = true

    public init(cornerRadius: CGFloat = 12, hasShadow: Bool = true) {
        self.cornerRadius = cornerRadius
        self.hasShadow = hasShadow
    }

    public func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.dsSystemControlBackground))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.dsSystemSeparator, lineWidth: 1))
            .shadow(color: hasShadow ? Color.black.opacity(0.05) : .clear, radius: 8, y: 4)
    }
}

public struct GlassBackground: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content.background(.ultraThinMaterial)
    }
}

public extension View {
    func dsCardStyle(cornerRadius: CGFloat = 12, hasShadow: Bool = true) -> some View {
        modifier(DSCardStyle(cornerRadius: cornerRadius, hasShadow: hasShadow))
    }

    func dsGlassBackground() -> some View {
        modifier(GlassBackground())
    }
}

// MARK: - Gradient Definitions

public extension LinearGradient {
    static func dsPrimaryGradient(for _: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [.orange, .orange.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
    }

    static func dsSecondaryGradient(for _: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [.blue, .blue.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
    }
}
