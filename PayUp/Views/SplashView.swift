import SwiftUI

/// Brief launch screen. Lime badge springs in, wordmark follows, one cheeky line.
struct SplashView: View {
    @State private var badgeIn = false
    @State private var textIn = false

    private static let quips = [
        "Right, who's paying?",
        "Gloves are still £2.",
        "Someone's forgotten the item of the week.",
        "The pot never lies.",
        "No hiding in the changing room.",
        "Late again, were we?"
    ]
    private let quip = quips.randomElement() ?? quips[0]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 112, height: 112)
                    Text("£")
                        .font(.system(size: 60, weight: .heavy))
                        .foregroundStyle(Theme.bg)
                }
                .scaleEffect(badgeIn ? 1 : 0.35)
                .rotationEffect(.degrees(badgeIn ? 0 : -28))
                .opacity(badgeIn ? 1 : 0)

                VStack(spacing: 8) {
                    Text("PayUp")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Theme.beige)
                    Text(quip)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                }
                .opacity(textIn ? 1 : 0)
                .offset(y: textIn ? 0 : 14)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { badgeIn = true }
            withAnimation(.easeOut(duration: 0.35).delay(0.22)) { textIn = true }
        }
    }
}
