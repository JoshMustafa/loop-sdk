#if os(iOS)
import SwiftUI

// MARK: - Design tokens
//
// The whole reporter UI is built from these. They mirror the design's
// "ink-on-paper" / "white-on-black" neutral palette — no host accent
// colour, no system blue. Anything visual should pull from here so the
// look stays consistent across screens.

enum LoopColors {
    static func bg(dark: Bool) -> Color {
        dark ? Color(hex: 0x0B0B0C) : Color(hex: 0xF6F6F7)
    }

    static func surf(dark: Bool) -> Color {
        dark ? Color(hex: 0x171718) : .white
    }

    static func ink(dark: Bool) -> Color {
        dark ? .white : Color(hex: 0x0E0E10)
    }

    static func onInk(dark: Bool) -> Color {
        dark ? Color(hex: 0x0B0B0C) : .white
    }

    static func text(dark: Bool) -> Color {
        dark ? .white : Color(hex: 0x0E0E10)
    }

    static func textSecondary(dark: Bool) -> Color {
        dark
            ? Color(red: 235/255, green: 235/255, blue: 240/255, opacity: 0.55)
            : Color(red: 20/255, green: 20/255, blue: 25/255, opacity: 0.6)
    }

    static func textTertiary(dark: Bool) -> Color {
        dark
            ? Color(red: 235/255, green: 235/255, blue: 240/255, opacity: 0.32)
            : Color(red: 20/255, green: 20/255, blue: 25/255, opacity: 0.4)
    }

    static func separator(dark: Bool) -> Color {
        dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.06)
    }

    static func subtleFill(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    // Status accents — same in both modes
    static let statusOpen = Color(hex: 0x7EC18A)
    static let statusInProgress = Color(hex: 0xE3B04A)
    static let statusPlanned = Color(hex: 0x7EB6E8)
    static let downvote = Color(hex: 0xFF453A)
}

// MARK: - Typography

enum LoopFont {
    /// Use the system font with rounded design? No — the design says SF Pro
    /// Display/Text. SwiftUI's `.default` maps to that on iOS.
    static func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Mono font used for IDs, status labels, timestamps, the brand pill.
    /// `.monospaced` design uses SF Mono on iOS.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Status pill (mono cap + dot)

struct LoopStatusLabel: View {
    let status: LoopItem.Status
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    private var color: Color {
        switch status {
        case .open: return LoopColors.statusOpen
        case .planned: return LoopColors.statusPlanned
        case .inProgress: return LoopColors.statusInProgress
        case .resolved, .shipped, .wontFix: return LoopColors.textTertiary(dark: dark)
        case .triaged: return LoopColors.statusPlanned
        case .other: return LoopColors.textTertiary(dark: dark)
        }
    }

    private var label: String {
        switch status {
        case .open: return String(localized: "Open", bundle: .module)
        case .planned: return String(localized: "Planned", bundle: .module)
        case .inProgress: return String(localized: "In progress", bundle: .module)
        case .triaged: return String(localized: "Triaged", bundle: .module)
        case .resolved: return String(localized: "Resolved", bundle: .module)
        case .shipped: return String(localized: "Shipped", bundle: .module)
        case .wontFix: return String(localized: "Won't fix", bundle: .module)
        case .other(let raw): return raw
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(LoopFont.mono(10, .medium))
                .kerning(0.5)
                .textCase(.uppercase)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Kind tag (×/+ + KIND in a bordered chip)

struct LoopKindTag: View {
    let kind: LoopItem.Kind
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let prefix = kind == .bug ? "×" : "+"
        let label = kind == .bug
            ? String(localized: "Bug", bundle: .module)
            : String(localized: "Feature", bundle: .module)
        let fg = kind == .bug ? LoopColors.text(dark: dark).opacity(0.85) : LoopColors.textSecondary(dark: dark)
        let border = kind == .bug
            ? (dark ? Color.white.opacity(0.18) : Color.black.opacity(0.16))
            : (dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10))

        HStack(spacing: 4) {
            Text(verbatim: prefix).font(LoopFont.mono(10.5, .medium))
            Text(label)
                .font(LoopFont.mono(10.5, .medium))
                .kerning(0.4)
                .textCase(.uppercase)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .overlay(
            RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: 1)
        )
    }
}

// MARK: - Mono caps label helper

struct MonoCaps: View {
    let text: String
    var size: CGFloat = 10.5
    var kerning: CGFloat = 0.6
    @Environment(\.colorScheme) private var scheme

    private var color: Color {
        LoopColors.textTertiary(dark: scheme == .dark)
    }

    var body: some View {
        Text(text.uppercased())
            .font(LoopFont.mono(size, .medium))
            .kerning(kerning)
            .foregroundStyle(color)
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
#endif
