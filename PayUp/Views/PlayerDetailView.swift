import SwiftUI
import SwiftData

struct PlayerDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var player: Player

    private var history: [Fine] {
        player.fines.sorted {
            let l = $0.match?.date ?? $0.createdAt
            let r = $1.match?.date ?? $1.createdAt
            if l != r { return l > r }
            return $0.createdAt > $1.createdAt
        }
    }

    private var grouped: [(match: Match?, fines: [Fine])] {
        var order: [PersistentIdentifier?] = []
        var buckets: [PersistentIdentifier?: [Fine]] = [:]
        for fine in history {
            let key = fine.match?.persistentModelID
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(fine)
        }
        return order.map { key in
            let fines = buckets[key] ?? []
            return (fines.first?.match, fines)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if history.isEmpty {
                    EmptyHint(
                        icon: "checkmark.seal",
                        title: "Spotless",
                        message: "\(player.name) hasn't been fined all season. Suspicious."
                    )
                    .cardSurface(Theme.Radius.card)
                } else {
                    ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                SectionLabel(text: group.match?.opponent ?? "Unassigned")
                                Spacer()
                                if let date = group.match?.date {
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
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(player.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.beige)
            }
        }
    }

    private var header: some View {
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
                    Text("\(player.fines.count) fine\(player.fines.count == 1 ? "" : "s") this season")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bg.opacity(0.55))
                }
                Spacer()
            }

            HStack(spacing: 0) {
                stat("Season total", Money.string(player.totalFined))
                Rectangle().fill(Theme.bg.opacity(0.12)).frame(width: 1, height: 34)
                stat("Paid", Money.string(player.totalPaid))
                Rectangle().fill(Theme.bg.opacity(0.12)).frame(width: 1, height: 34)
                stat("Owes", Money.string(player.balance))
            }

            if player.balance > 0 {
                Button {
                    settleAll()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Settle \(Money.string(player.balance))")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            } else if !player.fines.isEmpty {
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
            Text(value)
                .font(.tally(19, .bold))
                .foregroundStyle(Theme.bg)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.bg.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(_ fine: Fine) {
        withAnimation(.snappy(duration: 0.2)) { fine.setPaid(!fine.isPaid) }
        try? context.save()
        Haptics.tap()
    }

    private func settleAll() {
        withAnimation(.snappy(duration: 0.25)) {
            for fine in player.fines where !fine.isPaid { fine.setPaid(true) }
        }
        try? context.save()
        Haptics.bump()
    }
}

private struct FineHistoryRow: View {
    let fine: Fine
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: fine.isPaid ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(fine.isPaid ? Theme.accent : Theme.textFaint)

                Text(fine.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(fine.isPaid ? Theme.textDim : Theme.beige)
                    .strikethrough(fine.isPaid, color: Theme.textFaint)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(Money.string(fine.amountPence))
                    .font(.tally(15, .bold))
                    .foregroundStyle(fine.isPaid ? Theme.textFaint : Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
        }
        .buttonStyle(.plain)
    }
}
