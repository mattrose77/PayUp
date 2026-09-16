import SwiftUI

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.accent)
            Text("Loading…")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// Deliberately loud compared with an empty state: "nothing here" and "we
/// couldn't fetch anything" must never look the same.
struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(hex: 0xFF6B6B))
            Text("Couldn't load your team")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.beige)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: retry)
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .cardSurface(Theme.Radius.card)
    }
}

/// An empty list is a teaching moment, not a blank page — especially now that
/// nothing is seeded and a new team starts with nothing at all.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

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
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 6)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 28)
        .cardSurface(Theme.Radius.card)
    }
}

struct DataStateContainer<Content: View>: View {
    let state: TeamDataStore.LoadState
    let retry: () async -> Void
    @ViewBuilder var content: Content

    var body: some View {
        switch state {
        case .idle, .loading:
            LoadingView()
        case .failed(let message):
            ErrorStateView(message: message) { Task { await retry() } }
        case .loaded:
            content
        }
    }
}
