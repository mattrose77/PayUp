import SwiftUI

/// The matchday tally. Optimised for one thing: logging a lot of fines fast.
/// Pick a chip once, then tap every player it applies to.
struct TallyView: View {
    @Environment(\.teamDataStore) private var store
    let matchId: UUID

    @State private var selectedTypeId: UUID?
    @State private var recent: [Fine] = []
    @State private var flashed: UUID?
    @State private var inspecting: Player?
    @State private var sharing = false
    @State private var busy = false
    @State private var error: String?

    private var match: Match? { store.match(matchId) }
    private var players: [Player] { store.activePlayers }
    /// Everyone who belongs on this matchday's list: the active squad, plus
    /// anyone made inactive since who already has fines here — otherwise their
    /// fines count towards the total but vanish from the rows and the share card.
    private var roster: [Player] {
        store.players.filter { $0.active || !store.fines(forMatch: matchId, player: $0.id).isEmpty }
    }
    private var fineTypes: [FineType] { store.activeFineTypes }
    private var matchFines: [Fine] { store.fines(forMatch: matchId) }

    var body: some View {
        Group {
            if let match {
                content(for: match)
            } else {
                // The match was deleted on the other member's device.
                EmptyStateView(
                    icon: "questionmark.folder",
                    title: "Matchday not found",
                    message: "This matchday no longer exists — it may have been deleted."
                )
                .padding(18)
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .navigationDestination(item: $inspecting) { player in
            PlayerDetailView(playerId: player.id).environment(\.teamDataStore, store)
        }
        .sheet(isPresented: $sharing) { shareSheet }
        .onAppear {
            if selectedTypeId == nil { selectedTypeId = fineTypes.first?.id }
            if recent.isEmpty {
                recent = matchFines.sorted { $0.createdAt > $1.createdAt }.prefix(12).map { $0 }
            }
        }
    }

    @ViewBuilder
    private func content(for match: Match) -> some View {
        VStack(spacing: 0) {
            if !match.isComplete && !fineTypes.isEmpty && !players.isEmpty {
                chipRow
                Divider().overlay(Theme.surfaceHi)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    statusCard(for: match)
                    itemOfTheWeekStrip(for: match)

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xFF6B6B))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    if match.isComplete {
                        completedRoster
                    } else if players.isEmpty {
                        EmptyStateView(
                            icon: "person.2",
                            title: "No active players",
                            message: "Everyone who could be fined is inactive or hasn't been added yet. Add your squad in the Squad tab."
                        )
                    } else if fineTypes.isEmpty {
                        EmptyStateView(
                            icon: "sterlingsign.circle",
                            title: "No fines to give",
                            message: "You've got a squad but nothing to fine them for. Build your fines list in the Fines tab, then come back."
                        )
                    } else {
                        ForEach(roster) { player in
                            PlayerTallyRow(
                                player: player,
                                fines: store.fines(forMatch: matchId, player: player.id),
                                flashing: flashed == player.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { apply(to: player, match: match) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Adds the selected fine")
                            .accessibilityAction { apply(to: player, match: match) }
                            .contextMenu {
                                Button { inspecting = player } label: {
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
            .refreshable { await store.refresh() }

            if !match.isComplete { undoStrip }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(match?.opponent ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                if let match {
                    Text(match.playedOn, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Text(Money.string(matchFines.totalPence))
                .font(.tally(18, .bold))
                .foregroundStyle(matchFines.isEmpty ? Theme.textFaint : Theme.accent)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: matchFines.totalPence)

            Button { sharing = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
            }
            .accessibilityLabel("Share matchday")
            .disabled(matchFines.isEmpty)
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
                            selected: selectedTypeId == type.id,
                            countToday: matchFines.count { $0.fineTypeId == type.id }
                        )
                        .id(type.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selectedTypeId == type.id ? [.isButton, .isSelected] : .isButton)
                        .onTapGesture {
                            Haptics.tap()
                            withAnimation(.snappy(duration: 0.18)) { selectedTypeId = type.id }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .background(Theme.bg)
            .onChange(of: selectedTypeId) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .leading) }
            }
        }
    }

    private func itemOfTheWeekStrip(for match: Match) -> some View {
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

    private func statusCard(for match: Match) -> some View {
        HStack(spacing: 11) {
            Image(systemName: match.isComplete ? "lock.fill" : "lock.open")
                .font(.system(size: 13))
                .foregroundStyle(match.isComplete ? Theme.accent : Theme.textDim)

            VStack(alignment: .leading, spacing: 2) {
                Text(match.isComplete ? "Matchday complete" : "Matchday open")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                Text(statusDetail(for: match))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 8)

            Button { setComplete(!match.isComplete, match: match) } label: {
                Text(busy ? "…" : (match.isComplete ? "Reopen" : "Complete"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(match.isComplete ? Theme.bg : Theme.beige)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(match.isComplete ? Theme.accent : Theme.surfaceHi, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(14)
        .cardSurface()
        .padding(.bottom, 4)
    }

    private func statusDetail(for match: Match) -> String {
        if match.isComplete {
            return match.completedAt.map {
                "Locked \($0.formatted(.dateTime.day().month(.abbreviated)))"
            } ?? "No more fines can be added"
        }
        let count = matchFines.count
        return count == 0 ? "No fines yet" : "\(count) fine\(count == 1 ? "" : "s") so far"
    }

    @ViewBuilder
    private var completedRoster: some View {
        let fined = roster
            .map { ($0, store.fines(forMatch: matchId, player: $0.id)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.totalPence > $1.1.totalPence }

        if fined.isEmpty {
            EmptyStateView(
                icon: "checkmark.seal",
                title: "Nobody got done",
                message: "This matchday was locked with no fines on the board."
            )
        } else {
            ForEach(fined, id: \.0.id) { player, fines in
                Button { inspecting = player } label: {
                    PlayerTallyRow(player: player, fines: fines, flashing: false)
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
                            ForEach(recent.prefix(6)) { fine in
                                UndoPill(fine: fine, playerName: store.player(fine.playerId)?.name)
                                    .onTapGesture { undo(fine) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel("Undo \(fine.description) for \(store.player(fine.playerId)?.name ?? "player")")
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

    private var shareSheet: some View {
        let club = UserDefaults.standard.string(forKey: Club.storageKey) ?? Club.fallbackName
        let closing = UserDefaults.standard.string(forKey: Club.closingKey) ?? Club.defaultClosing
        let current = match
        return ShareSheet(
            title: current?.opponent ?? "Matchday",
            card: ShareCard(
                clubName: club,
                subtitle: current.map { "v \($0.opponent) — \(ShareSummary.dateString($0.playedOn))" } ?? "",
                rows: ShareSummary.matchdayTallies(fines: matchFines, players: roster),
                bigLabel: "today's damage",
                bigAmount: Money.string(matchFines.totalPence),
                closing: closing
            ),
            filename: "payup-\((current?.opponent ?? "matchday").replacingOccurrences(of: " ", with: "-").lowercased()).png"
        )
    }

    // MARK: - Actions

    private func apply(to player: Player, match: Match) {
        guard !match.isComplete,
              let typeId = selectedTypeId,
              let type = fineTypes.first(where: { $0.id == typeId }) else { return }
        error = nil
        Haptics.tap()
        withAnimation(.snappy(duration: 0.2)) { flashed = player.id }

        Task {
            do {
                let fine = try await store.addFine(player: player, type: type, match: match)
                withAnimation(.snappy(duration: 0.2)) {
                    recent.insert(fine, at: 0)
                    if recent.count > 12 { recent.removeLast(recent.count - 12) }
                }
            } catch {
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(320))
            if flashed == player.id {
                withAnimation(.easeOut(duration: 0.2)) { flashed = nil }
            }
        }
    }

    private func undo(_ fine: Fine) {
        error = nil
        Task {
            do {
                try await store.deleteFine(fine)
                withAnimation(.snappy(duration: 0.2)) {
                    recent.removeAll { $0.id == fine.id }
                }
                Haptics.bump()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func undoLast(for player: Player) {
        let theirs = store.fines(forMatch: matchId, player: player.id)
            .sorted { $0.createdAt > $1.createdAt }
        if let last = theirs.first { undo(last) }
    }

    private func setComplete(_ complete: Bool, match: Match) {
        busy = true
        error = nil
        Task {
            do {
                try await store.setMatchComplete(match, complete: complete)
                if complete { recent.removeAll() }
                Haptics.bump()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
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
    let fines: [Fine]
    let flashing: Bool

    /// Reads each fine's own description — never joins back to fine_types,
    /// which may have been deleted.
    private var summary: [(String, Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for fine in fines.sorted(by: { $0.createdAt > $1.createdAt }) {
            if counts[fine.description] == nil { order.append(fine.description) }
            counts[fine.description, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    var body: some View {
        HStack(spacing: 13) {
            Avatar(initials: player.initials, size: 38, highlighted: !fines.isEmpty)

            VStack(alignment: .leading, spacing: 3) {
                Text(player.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                if summary.isEmpty {
                    Text("Clean").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                } else {
                    Text(summary.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            Text(Money.string(fines.totalPence))
                .font(.tally(19, .bold))
                .foregroundStyle(fines.isEmpty ? Theme.textFaint : Theme.accent)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: fines.totalPence)
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
    let playerName: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .bold))
            Text(playerName?.split(separator: " ").first.map(String.init) ?? "—")
                .font(.system(size: 13, weight: .semibold))
            Text(fine.description)
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
