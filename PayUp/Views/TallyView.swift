import SwiftUI
import SwiftData

/// The matchday tally. Optimised for one thing: logging a lot of fines fast.
/// Pick a chip once, then tap every player it applies to.
///
/// Once the matchday is marked complete the screen becomes a read-only summary:
/// no chips, no undo, and rows lead to the player rather than issuing a fine.
struct TallyView: View {
    @Environment(\.modelContext) private var context
    @Bindable var match: Match

    @Environment(\.teamSession) private var session
    @Query(sort: [SortDescriptor(\Player.name)]) private var allPlayers: [Player]
    @Query(filter: #Predicate<FineType> { !$0.isArchived },
           sort: [SortDescriptor(\FineType.sortOrder)]) private var allFineTypes: [FineType]

    private var players: [Player] { allPlayers.scoped(to: session.team?.id) }
    private var fineTypes: [FineType] { allFineTypes.scoped(to: session.team?.id) }

    @State private var selectedType: FineType?
    @State private var recent: [Fine] = []
    @State private var flashed: PersistentIdentifier?
    @State private var inspecting: Player?
    @State private var sharing = false

    @AppStorage(Club.storageKey) private var clubName = ""
    @AppStorage(Club.closingKey) private var closingLine = Club.defaultClosing

    var body: some View {
        VStack(spacing: 0) {
            if !match.isComplete {
                chipRow
                Divider().overlay(Theme.surfaceHi)
            }

            if players.isEmpty {
                EmptyHint(
                    icon: "person.2",
                    title: "No squad yet",
                    message: "Add players in the Squad tab, then come back to start fining."
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        statusCard

                        itemOfTheWeekStrip

                        if match.isComplete {
                            completedRoster
                        } else {
                            ForEach(players) { player in
                                PlayerTallyRow(
                                    player: player,
                                    match: match,
                                    flashing: flashed == player.persistentModelID
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { apply(to: player) }
                                .contextMenu {
                                    NavigationLink { PlayerDetailView(player: player) } label: {
                                        Label("Player detail", systemImage: "person.text.rectangle")
                                    }
                                    Button(role: .destructive) { undoLast(for: player) } label: {
                                        Label("Undo last fine", systemImage: "arrow.uturn.backward")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }

            if !match.isComplete { undoStrip }
        }
        .screenBackground()
        .navigationDestination(item: $inspecting) { player in
            PlayerDetailView(player: player)
        }
        .sheet(isPresented: $sharing) {
            let club = clubName.trimmingCharacters(in: .whitespaces).isEmpty
                ? Club.fallbackName : clubName
            ShareSheet(
                title: match.opponent,
                card: ShareCard(
                    clubName: club,
                    subtitle: "v \(match.opponent) — \(ShareSummary.dateString(match.date))",
                    rows: ShareSummary.matchdayTallies(match: match, players: players),
                    bigLabel: "today's damage",
                    bigAmount: Money.string(match.total),
                    closing: closingLine
                ),
                filename: "payup-\(match.opponent.replacingOccurrences(of: " ", with: "-").lowercased()).png"
            )
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(match.opponent)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.beige)
                    Text(match.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Text(Money.string(match.total))
                    .font(.tally(18, .bold))
                    .foregroundStyle(match.total > 0 ? Theme.accent : Theme.textFaint)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: match.total)

                Button { sharing = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                }
                .disabled(match.fines.isEmpty)
            }
        }
        .onAppear {
            if selectedType == nil { selectedType = fineTypes.first }
            recent = recent.filter { $0.modelContext != nil }
            if recent.isEmpty {
                recent = match.fines.sorted { $0.createdAt > $1.createdAt }.prefix(12).map { $0 }
            }
        }
    }

    // MARK: - Chips

    private var chipRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(fineTypes) { type in
                        FineChip(
                            type: type,
                            selected: selectedType?.persistentModelID == type.persistentModelID,
                            countToday: countToday(type)
                        )
                        .id(type.persistentModelID)
                        .onTapGesture {
                            Haptics.tap()
                            withAnimation(.snappy(duration: 0.18)) { selectedType = type }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .background(Theme.bg)
            .onChange(of: selectedType?.persistentModelID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .leading)
                }
            }
        }
    }

    private var itemOfTheWeekStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text("Item of the week")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Text(match.itemOfTheWeek.isEmpty ? "Not set" : match.itemOfTheWeek)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.beige)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .cardSurface(14)
        .padding(.bottom, 4)
    }

    // MARK: - Complete / reopen

    private var statusCard: some View {
        HStack(spacing: 11) {
            Image(systemName: match.isComplete ? "lock.fill" : "lock.open")
                .font(.system(size: 13))
                .foregroundStyle(match.isComplete ? Theme.accent : Theme.textDim)

            VStack(alignment: .leading, spacing: 2) {
                Text(match.isComplete ? "Matchday complete" : "Matchday open")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                Text(statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 8)

            // Quiet while open so it doesn't compete with tapping players;
            // accent once locked, when it's the only thing left to do here.
            Button(action: match.isComplete ? reopen : complete) {
                Text(match.isComplete ? "Reopen" : "Complete")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(match.isComplete ? Theme.bg : Theme.beige)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(match.isComplete ? Theme.accent : Theme.surfaceHi, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .cardSurface()
        .padding(.bottom, 4)
    }

    private var statusDetail: String {
        if match.isComplete {
            return match.completedAt.map {
                "Locked \($0.formatted(.dateTime.day().month(.abbreviated)))"
            } ?? "No more fines can be added"
        }
        let count = match.fines.count
        return count == 0 ? "No fines yet" : "\(count) fine\(count == 1 ? "" : "s") so far"
    }

    /// Read-only receipt: only the players who actually picked something up,
    /// heaviest first. Tapping opens the player rather than issuing a fine.
    @ViewBuilder
    private var completedRoster: some View {
        let fined = players
            .filter { total(for: $0) > 0 }
            .sorted { total(for: $0) > total(for: $1) }

        if fined.isEmpty {
            EmptyHint(
                icon: "checkmark.seal",
                title: "Nobody got done",
                message: "This matchday was locked with no fines on the board."
            )
            .cardSurface(Theme.Radius.card)
        } else {
            ForEach(fined) { player in
                Button {
                    inspecting = player
                } label: {
                    PlayerTallyRow(player: player, match: match, flashing: false)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Undo

    private var undoStrip: some View {
        Group {
            if recent.isEmpty {
                EmptyView()
            } else {
                VStack(spacing: 0) {
                    Divider().overlay(Theme.surfaceHi)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Text("UNDO")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(Theme.textFaint)
                                .padding(.trailing, 2)
                            ForEach(recent.prefix(6), id: \.persistentModelID) { fine in
                                UndoPill(fine: fine)
                                    .onTapGesture { undo(fine) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .background(Theme.bg)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Actions

    private func apply(to player: Player) {
        guard !match.isComplete, let type = selectedType else { return }
        let fine = Fine(player: player, fineType: type, match: match)
        context.insert(fine)
        try? context.save()

        Haptics.tap()
        withAnimation(.snappy(duration: 0.2)) {
            recent.insert(fine, at: 0)
            if recent.count > 12 { recent.removeLast(recent.count - 12) }
            flashed = player.persistentModelID
        }
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            if flashed == player.persistentModelID {
                withAnimation(.easeOut(duration: 0.2)) { flashed = nil }
            }
        }
    }

    private func undo(_ fine: Fine) {
        withAnimation(.snappy(duration: 0.2)) {
            recent.removeAll { $0.persistentModelID == fine.persistentModelID }
        }
        guard fine.modelContext != nil else { return }
        context.delete(fine)
        try? context.save()
        Haptics.bump()
    }

    private func undoLast(for player: Player) {
        let todays = match.fines
            .filter { $0.player?.persistentModelID == player.persistentModelID }
            .sorted { $0.createdAt > $1.createdAt }
        if let last = todays.first { undo(last) }
    }

    private func complete() {
        withAnimation(.snappy(duration: 0.3)) {
            match.isComplete = true
            match.completedAt = Date()
            recent.removeAll()
        }
        try? context.save()
        Haptics.bump()
    }

    private func reopen() {
        withAnimation(.snappy(duration: 0.3)) {
            match.isComplete = false
            match.completedAt = nil
        }
        try? context.save()
        Haptics.bump()
    }

    private func countToday(_ type: FineType) -> Int {
        match.fines.count { $0.fineType?.persistentModelID == type.persistentModelID }
    }

    private func total(for player: Player) -> Int {
        match.fines
            .filter { $0.player?.persistentModelID == player.persistentModelID }
            .reduce(0) { $0 + $1.amountPence }
    }
}

// MARK: - Chip

private struct FineChip: View {
    let type: FineType
    let selected: Bool
    let countToday: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(type.name)
                .font(.system(size: 14, weight: .semibold))
            Text(Money.string(type.amountPence))
                .font(.tally(13, .bold))
                .foregroundStyle(selected ? Theme.bg.opacity(0.6) : Theme.accent)
            if countToday > 0 {
                Text("\(countToday)")
                    .font(.tally(11, .bold))
                    .foregroundStyle(selected ? Theme.accent : Theme.beige)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(selected ? Theme.bg : Theme.surfaceHi, in: Capsule())
            }
        }
        .foregroundStyle(selected ? Theme.bg : Theme.beige)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            selected ? Theme.accent : Theme.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        )
    }
}

// MARK: - Player row

private struct PlayerTallyRow: View {
    let player: Player
    let match: Match
    let flashing: Bool

    private var todays: [Fine] {
        match.fines
            .filter { $0.player?.persistentModelID == player.persistentModelID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var todayTotal: Int { todays.reduce(0) { $0 + $1.amountPence } }

    /// "Late arrival ×2" style summary, most recent first.
    private var summary: [(String, Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for fine in todays.reversed() {
            if counts[fine.label] == nil { order.append(fine.label) }
            counts[fine.label, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    var body: some View {
        HStack(spacing: 13) {
            Avatar(initials: player.initials, size: 38, highlighted: !todays.isEmpty)

            VStack(alignment: .leading, spacing: 3) {
                Text(player.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                if summary.isEmpty {
                    Text("Clean")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                } else {
                    Text(summary.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            Text(Money.string(todayTotal))
                .font(.tally(19, .bold))
                .foregroundStyle(todayTotal > 0 ? Theme.accent : Theme.textFaint)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: todayTotal)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(flashing ? Theme.accent.opacity(0.22) : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: flashing ? 1.5 : 0)
        )
    }
}

private struct UndoPill: View {
    let fine: Fine

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .bold))
            Text(fine.player?.name.split(separator: " ").first.map(String.init) ?? "—")
                .font(.system(size: 13, weight: .semibold))
            Text(fine.label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.beige)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: Capsule())
    }
}
