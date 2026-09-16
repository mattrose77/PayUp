import SwiftUI

struct ShameBoardView: View {
    @Environment(\.teamDataStore) private var store
    @State private var sharing = false

    private struct Standing: Identifiable {
        let player: Player
        let fines: [Fine]
        var id: UUID { player.id }
    }

    private var standings: [Standing] {
        store.players
            .map { Standing(player: $0, fines: store.fines(forPlayer: $0.id)) }
            .filter { !$0.fines.isEmpty }
            .sorted {
                if $0.fines.totalPence != $1.fines.totalPence {
                    return $0.fines.totalPence > $1.fines.totalPence
                }
                return $0.player.name.localizedCaseInsensitiveCompare($1.player.name) == .orderedAscending
            }
    }

    private var cleanest: (player: Player, tied: Int)? {
        let candidates = store.players.map { ($0, store.fines(forPlayer: $0.id).totalPence) }
        guard let best = candidates.min(by: {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }) else { return nil }
        let tied = candidates.count { $0.1 == best.1 } - 1
        return (best.0, tied)
    }

    private var mostCommon: (label: String, count: Int)? {
        var counts: [String: Int] = [:]
        for fine in store.fines { counts[fine.description, default: 0] += 1 }
        return counts.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedDescending
        }.map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ScreenHeader(title: "Shame board", subtitle: "Season standings") {
                        if !store.fines.isEmpty {
                            HeaderIconButton(systemName: "square.and.arrow.up") { sharing = true }
                        }
                    }

                    DataStateContainer(state: store.state, retry: { await store.refresh() }) {
                        if store.fines.isEmpty {
                            EmptyStateView(
                                icon: "flame",
                                title: "Nothing to see here",
                                message: "The shame board fills up once fines start landing. Log a matchday and the table builds itself."
                            )
                        } else {
                            if let top = standings.first { offenderCard(top) }

                            HStack(spacing: 12) {
                                if let common = mostCommon {
                                    smallCard(icon: "repeat", label: "Most common",
                                              value: common.label, detail: "\(common.count)×")
                                }
                                if let clean = cleanest {
                                    smallCard(
                                        icon: "sparkles", label: "Cleanest",
                                        value: clean.player.name,
                                        detail: clean.tied > 0
                                            ? "\(Money.string(store.fines(forPlayer: clean.player.id).totalPence)) · \(clean.tied) tied"
                                            : Money.string(store.fines(forPlayer: clean.player.id).totalPence)
                                    )
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(text: "The table")
                                    .padding(.horizontal, 4)
                                    .padding(.top, 6)
                                ForEach(Array(standings.enumerated()), id: \.element.id) { index, standing in
                                    NavigationLink {
                                        PlayerDetailView(playerId: standing.player.id)
                                            .environment(\.teamDataStore, store)
                                    } label: {
                                        rankRow(index: index, standing: standing)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .refreshable { await store.refresh() }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .task { await store.loadIfNeeded() }
            .sheet(isPresented: $sharing) { shareSheet }
        }
    }

    private var shareSheet: some View {
        let club = UserDefaults.standard.string(forKey: Club.storageKey) ?? Club.fallbackName
        let closing = UserDefaults.standard.string(forKey: Club.closingKey) ?? Club.defaultClosing
        return ShareSheet(
            title: "Season so far",
            card: ShareCard(
                clubName: club,
                subtitle: "Season so far — \(store.matches.count) matchday\(store.matches.count == 1 ? "" : "s")",
                rows: standings.prefix(3).map {
                    ShareSummary.Tally(
                        name: $0.player.name,
                        details: ["\($0.fines.count) fine\($0.fines.count == 1 ? "" : "s")"],
                        amountPence: $0.fines.totalPence
                    )
                },
                bigLabel: "season total",
                bigAmount: Money.string(store.seasonStats.total),
                closing: closing
            ),
            filename: "payup-season.png"
        )
    }

    private func offenderCard(_ standing: Standing) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BIGGEST OFFENDER")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.bg.opacity(0.5))

            HStack(spacing: 14) {
                Text(standing.player.initials)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.beige)
                    .frame(width: 58, height: 58)
                    .background(Theme.bg, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(standing.player.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.bg)
                    Text("\(standing.fines.count) fines · \(Money.string(standing.fines.outstandingPence)) outstanding")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bg.opacity(0.55))
                }
                Spacer()
                Text(Money.string(standing.fines.totalPence))
                    .font(.tally(30, .bold))
                    .foregroundStyle(Theme.bg)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.beige, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func smallCard(icon: String, label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.textDim)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.beige)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(detail).font(.tally(14, .bold)).foregroundStyle(Theme.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .cardSurface(Theme.Radius.card)
    }

    private func rankRow(index: Int, standing: Standing) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.tally(13, .bold))
                .foregroundStyle(index == 0 ? Theme.accent : Theme.textFaint)
                .frame(width: 20, alignment: .leading)

            Avatar(initials: standing.player.initials, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(standing.player.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                Text("\(standing.fines.count) fine\(standing.fines.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.string(standing.fines.totalPence))
                    .font(.tally(16, .bold))
                    .foregroundStyle(Theme.accent)
                if standing.fines.outstandingPence > 0 {
                    Text("\(Money.string(standing.fines.outstandingPence)) owed")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                } else {
                    Text("settled").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}
