import SwiftUI

struct Avatar: View {
    let initials: String
    var size: CGFloat = 40
    var highlighted: Bool = false

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(highlighted ? Theme.bg : Theme.beige)
            .frame(width: size, height: size)
            .background(highlighted ? Theme.accent : Theme.surfaceHi, in: Circle())
    }
}

/// The pot bar — the only place a filled accent bar appears.
struct PotBar: View {
    let fraction: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bg.opacity(0.35))
                Capsule()
                    .fill(Theme.accentDeep)
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(.snappy(duration: 0.3), value: fraction)
    }
}

struct SeasonPotCard: View {
    let stats: SeasonStats
    @AppStorage(Club.storageKey) private var clubName = ""

    private var displayName: String {
        let trimmed = clubName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Club.fallbackName : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName.uppercased())
                        .font(.system(size: 15, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.bg.opacity(0.85))
                    Text("SEASON POT")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.bg.opacity(0.45))
                }
                Spacer()
                // Once it's all in, this just repeats the collected figure below.
                if stats.outstanding > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.string(stats.total))
                            .font(.tally(15, .bold))
                            .foregroundStyle(Theme.bg.opacity(0.5))
                        Text("TOTAL FINED")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.bg.opacity(0.45))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.25), value: stats.outstanding > 0)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Money.string(stats.collected))
                    .font(.tally(44, .bold))
                    .foregroundStyle(Theme.bg)
                Text("collected")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.bg.opacity(0.5))
            }

            PotBar(fraction: stats.fraction)

            HStack {
                Label(Money.string(stats.outstanding), systemImage: "hourglass")
                    .font(.tally(14, .semibold))
                    .foregroundStyle(Theme.bg.opacity(0.75))
                Text("outstanding")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.bg.opacity(0.5))
                Spacer()
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.beige, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.textDim)
    }
}

/// Flat pill used for tallies and small counts.
struct Token: View {
    let text: String
    var tint: Color = Theme.textDim
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surfaceHi, in: Capsule())
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.beige)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.bg : Theme.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                isEnabled ? Theme.accent : Theme.surfaceHi,
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.beige)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    func cardSurface(_ radius: CGFloat = Theme.Radius.row) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func screenBackground() -> some View {
        background(Theme.bg.ignoresSafeArea())
    }
}

enum Haptics {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    static func bump() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

/// Root screens draw their own header instead of a system nav title, so the
/// beige/charcoal palette holds all the way to the status bar.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.beige)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            trailing
        }
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct HeaderIconButton: View {
    let systemName: String
    /// Read by VoiceOver; the symbol alone says nothing useful.
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.beige)
                .frame(width: 44, height: 44)
                .background(Theme.surface, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct HeaderAddButton: View {
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.bg)
                .frame(width: 44, height: 44)
                .background(Theme.accent, in: Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel("New matchday")
    }
}
