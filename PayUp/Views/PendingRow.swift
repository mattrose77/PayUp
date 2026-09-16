import SwiftUI

/// A row that hasn't landed yet, or didn't. Shared by the squad and fines
/// lists so both rapid-entry screens behave identically.
struct PendingRow: View {
    let title: String
    let detail: String?
    let state: RowState
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            marker

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.isFailed ? Theme.beige : Theme.textDim)
                if let message = state.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xFF6B6B))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                } else {
                    Text("Saving…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                }
            }

            Spacer(minLength: 6)

            if state.isFailed {
                Button("Retry", action: retry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(state.isFailed ? Color(hex: 0xFF6B6B).opacity(0.5) : .clear, lineWidth: 1)
        )
        .opacity(state.isPending ? 0.75 : 1)
        .swipeActions(edge: .trailing) {
            if state.isFailed {
                Button(role: .destructive, action: discard) {
                    Label("Discard", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if state.isFailed {
                Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                Button(role: .destructive, action: discard) {
                    Label("Discard", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch state {
        case .pending:
            ProgressView()
                .tint(Theme.accent)
                .frame(width: 40, height: 40)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: 0xFF6B6B))
                .frame(width: 40, height: 40)
        }
    }
}
