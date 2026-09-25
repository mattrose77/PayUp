import SwiftUI

enum Theme {
    /// Base charcoal the whole app sits on.
    static let bg = Color(hex: 0x22211F)
    /// Raised surface — cards, rows, chips.
    static let surface = Color(hex: 0x2A2926)
    /// Second step up — pressed states, dividers made of fills.
    static let surfaceHi = Color(hex: 0x34322D)
    /// Beige off-white: primary text, and the fill of hero cards.
    static let beige = Color(hex: 0xEDE7DA)
    static let textDim = Color(hex: 0xEDE7DA).opacity(0.55)
    static let textFaint = Color(hex: 0xEDE7DA).opacity(0.28)
    /// The one accent. Totals, selected states, the pot bar.
    static let accent = Color(hex: 0xC4F82A)
    /// The accent taken deeper and off the boil, for the rare places it has to
    /// sit on beige. The electric lime is the same brightness as the card it
    /// lands on, so on light ground it both glares and vanishes.
    static let accentDeep = Color(hex: 0x55741A)
    /// Errors and the one irreversible action. Never decorative.
    static let danger = Color(hex: 0xFF6B6B)

    enum Radius {
        static let card: CGFloat = 22
        static let row: CGFloat = 18
        static let chip: CGFloat = 14
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Font {
    /// Tabular figures so running totals don't jitter as they climb.
    static func tally(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

/// Money is stored as integer pence everywhere; this is the only place that
/// turns it back into pounds for display.
enum Money {
    static func string(_ pence: Int) -> String {
        let negative = pence < 0
        let magnitude = abs(pence)
        let body = magnitude % 100 == 0
            ? "£\(magnitude / 100)"
            : String(format: "£%d.%02d", magnitude / 100, magnitude % 100)
        return negative ? "-" + body : body
    }

    /// No fine is worth more than this. Also keeps a long run of digits (or a
    /// pasted "inf") from overflowing Int — this runs on every keystroke — and
    /// stays well inside the Postgres `integer` column.
    static let maxPence = 1_000_000

    /// Parses "2", "2.50", "2,50" into pence. Nil if it isn't a number or is
    /// out of range.
    static func pence(from text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "£", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        let pence = (value * 100).rounded()
        guard pence <= Double(maxPence) else { return nil }
        return Int(pence)
    }
}
