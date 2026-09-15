import SwiftUI
import SwiftData

struct ShameBoardView: View {
    @Environment(\.teamSession) private var session
    @Query(sort: [SortDescriptor(\Player.name)]) private var allPlayers: [Player]
    @Query private var everyFine: [Fine]
    @Query private var allMatches: [Match]

    private var players: [Player] { allPlayers.scoped(to: session.team?.id) }
    private var allFines: [Fine] { everyFine.scoped(to: session.team?.id) }
    private var matches: [Match] { allMatches.scoped(to: session.team?.id) }
    @AppStorage(Club.storageKey) private var clubName = ""
    @AppStorage(Club.closingKey) private var closingLine = Club.defaultClosing

    @State private var sharing = false

    private var ranked: [Player] {
        players.filter { !$0.fines.isEmpty }
            .sorted {
                if $0.totalFined != $1.totalFined { return $0.totalFined > $1.totalFined }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private var biggestOffender: Player? { ranked.first }

    private var cleanest: (player: Player, tiedWith: Int)? {
        guard let best = players.min(by: {
            if $0.totalFined != $1.totalFined { return $0.totalFined < $1.totalFined }
            if $0.fines.count != $1.fines.count { return $0.fines.count < $1.fines.count }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) else { return nil }
        let tied = players.count { $0.totalFined == best.totalFined } - 1
        return (best, tied)
    }

    private var mostCommonFine: (label: String, count: Int)? {
        var counts: [String: Int] = [:]
        for fine in allFines { counts[fine.label, default: 0] += 1 }
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
                        HeaderIconButton(systemName: "square.and.arrow.up") { sharing = true }
                            .disabled(allFines.isEmpty)
                            .opacity(allFines.isEmpty ? 0.35 : 1)
                    }

                    if allFines.isEmpty {
                        EmptyHint(
                            icon: "flame",
                            title: "Nothing to see here",
                            message: "The shame board fills up once fines start landing."
                        )
                        .cardSurface(Theme.Radius.card)
                    } else {
                        if let offender = biggestOffender {
                            offenderCard(offender)
                        }

                        HStack(spacing: 12) {
                            if let common = mostCommonFine {
                                smallCard(
                                    icon: "repeat",
                                    label: "Most common",
                                    value: common.label,
                                    detail: "\(common.count)×"
                                )
                            }
                            if let clean = cleanest {
                                smallCard(
                                    icon: "sparkles",
                                    label: "Cleanest",
                                    value: clean.player.name,
                                    detail: clean.tiedWith > 0
                                        ? "\(Money.string(clean.player.totalFined)) · \(clean.tiedWith) tied"
                                        : Money.string(clean.player.totalFined)
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "The table")
                                .padding(.horizontal, 4)
                                .padding(.top, 6)
                            ForEach(Array(ranked.enumerated()), id: \.element.persistentModelID) { index, player in
                                NavigationLink {
                                    PlayerDetailView(player: player)
                                } label: {
                                    rankRow(index: index, player: player)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $sharing) {
                let season = SeasonStats(fines: allFines)
                let club = clubName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? Club.fallbackName : clubName
                ShareSheet(
                    title: "Season so far",
                    card: ShareCard(
                        clubName: club,
                        subtitle: "Season so far — \(matches.count) matchday\(matches.count == 1 ? "" : "s")",
                        rows: ShareSummary.seasonPodium(players),
                        bigLabel: "season total",
                        bigAmount: Money.string(season.total),
                        closing: closingLine
                    ),
                    filename: "payup-season.png"
                )
            }
        }
    }

    private func offenderCard(_ player: Player) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BIGGEST OFFENDER")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.bg.opacity(0.5))

            HStack(spacing: 14) {
                Text(player.initials)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.beige)
                    .frame(width: 58, height: 58)
                    .background(Theme.bg, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.bg)
                    Text("\(player.fines.count) fines · \(Money.string(player.balance)) outstanding")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bg.opacity(0.55))
                }
                Spacer()
                Text(Money.string(player.totalFined))
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
            Text(detail)
                .font(.tally(14, .bold))
                .foregroundStyle(Theme.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .cardSurface(Theme.Radius.card)
    }

    private func rankRow(index: Int, player: Player) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.tally(13, .bold))
                .foregroundStyle(index == 0 ? Theme.accent : Theme.textFaint)
                .frame(width: 20, alignment: .leading)

            Avatar(initials: player.initials, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                Text("\(player.fines.count) fine\(player.fines.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.string(player.totalFined))
                    .font(.tally(16, .bold))
                    .foregroundStyle(Theme.accent)
                if player.balance > 0 {
                    Text("\(Money.string(player.balance)) owed")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                } else {
                    Text("settled")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}
