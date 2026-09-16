import SwiftUI

struct PlayerDetailView: View {
    @Environment(\.teamDataStore) private var store
    let playerId: UUID

    @State private var error: String?
    @State private var busy = false

    private var player: Player? { store.player(playerId) }
    private var fines: [Fine] { store.fines(forPlayer: playerId) }

    private var grouped: [(match: Match?, fines: [Fine])] {
        var order: [UUID] = []
        var buckets: [UUID: [Fine]] = [:]
        let sorted = fines.sorted {
            let l = store.match($0.matchId)?.playedOn ?? $0.createdAt
            let r = store.match($1.matchId)?.playedOn ?? $1.createdAt
            if l != r { return l > r }
            return $0.createdAt > $1.createdAt
        }
        for fine in sorted {
            if buckets[fine.matchId] == nil { order.append(fine.matchId) }
            buckets[fine.matchId, default: []].append(fine)
        }
        return order.map { (store.match($0), buckets[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let player {
                    header(player)

                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B))
                    }

                    if fines.isEmpty {
                        EmptyStateView(
                            icon: "checkmark.seal",
                            title: "Spotless",
                            message: "\(player.name) hasn't been fined all season. Suspicious."
                        )
                    } else {
                        ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    SectionLabel(text: group.match?.opponent ?? "Unassigned")
                                    Spacer()
                                    if let date = group.match?.playedOn {
                                        Text(date, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textFaint)
                                    }
                                }
                                .padding(.horizontal, 4)

                                VStack(spacing: 1) {
                                    ForEach(group.fines) { fine in
                                        FineHistoryRow(fine: fine) { toggle(fine) }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                            }
                            .padding(.top, 6)
                        }
                    }
                } else {
                    EmptyStateView(
                        icon: "questionmark.folder",
                        title: "Player not found",
                        message: "They may have been removed from the squad."
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .refreshable { await store.refresh() }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(player?.name ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.beige)
            }
        }
    }

    private func header(_ player: Player) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Text(player.initials)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.beige)
                    .frame(width: 52, height: 52)
                    .background(Theme.bg, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.bg)
                    Text("\(fines.count) fine\(fines.count == 1 ? "" : "s") this season"
                         + (player.active ? "" : " · inactive"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bg.opacity(0.55))
                }
                Spacer()
            }

            HStack(spacing: 0) {
                stat("Season total", Money.string(fines.totalPence))
                Rectangle().fill(Theme.bg.opacity(0.12)).frame(width: 1, height: 34)
                stat("Paid", Money.string(fines.paidPence))
                Rectangle().fill(Theme.bg.opacity(0.12)).frame(width: 1, height: 34)
                stat("Owes", Money.string(fines.outstandingPence))
            }

            if fines.outstandingPence > 0 {
                Button(action: settleAll) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(busy ? "Settling…" : "Settle \(Money.string(fines.outstandingPence))")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(busy)
            } else if !fines.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("All square")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.bg.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
        }
        .padding(20)
        .background(Theme.beige, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.tally(19, .bold)).foregroundStyle(Theme.bg)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.bg.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(_ fine: Fine) {
        error = nil
        Task {
            do {
                try await store.setFinePaid(fine, paid: !fine.paid)
                Haptics.tap()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func settleAll() {
        let unpaid = fines.filter { !$0.paid }
        guard !unpaid.isEmpty else { return }
        busy = true
        error = nil
        Task {
            do {
                try await store.settle(unpaid)
                Haptics.bump()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct FineHistoryRow: View {
    let fine: Fine
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: fine.paid ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(fine.paid ? Theme.accent : Theme.textFaint)

                // The fine's own description, not a lookup — the type may be gone.
                Text(fine.description)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(fine.paid ? Theme.textDim : Theme.beige)
                    .strikethrough(fine.paid, color: Theme.textFaint)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(Money.string(fine.amountPence))
                    .font(.tally(15, .bold))
                    .foregroundStyle(fine.paid ? Theme.textFaint : Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
