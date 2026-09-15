import SwiftUI
import SwiftData

struct MatchesView: View {
    let auth: AuthService
    @Environment(\.modelContext) private var context
    @Environment(\.teamSession) private var session
    @Query(sort: \Match.date, order: .reverse) private var allMatches: [Match]
    @Query private var everyFine: [Fine]
    @Query(sort: \Player.rotaOrder) private var allPlayers: [Player]

    private var matches: [Match] { allMatches.scoped(to: session.team?.id) }
    private var allFines: [Fine] { everyFine.scoped(to: session.team?.id) }
    private var players: [Player] { allPlayers.scoped(to: session.team?.id) }

    @State private var showingNewMatch = false
    @State private var showingSettings = false
    @State private var pendingDelete: Match?

    private var stats: SeasonStats { SeasonStats(fines: allFines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ScreenHeader(title: "PayUp", subtitle: "Matchday fines") {
                        HStack(spacing: 10) {
                            HeaderIconButton(systemName: "gearshape.fill") { showingSettings = true }
                            HeaderAddButton(enabled: !players.isEmpty) { showingNewMatch = true }
                        }
                    }

                    SeasonPotCard(stats: stats)
                        .padding(.bottom, 6)

                    HStack {
                        SectionLabel(text: "Matchdays")
                        Spacer()
                        Text("\(matches.count)")
                            .font(.tally(12, .bold))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .padding(.horizontal, 4)

                    if matches.isEmpty {
                        EmptyHint(
                            icon: "sportscourt",
                            title: "No matchdays yet",
                            message: players.isEmpty
                                ? "Add your squad first, then start a matchday to begin fining."
                                : "Tap + to start a matchday and open the tally."
                        )
                        .cardSurface(Theme.Radius.card)
                    } else {
                        ForEach(matches) { match in
                            NavigationLink {
                                TallyView(match: match)
                            } label: {
                                MatchRow(match: match)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = match
                                } label: {
                                    Label("Delete matchday", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewMatch) {
                NewMatchSheet(players: players)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(auth: auth)
            }
            .alert(
                pendingDelete.map { "Delete \($0.opponent)?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { match in
                Button("Delete matchday", role: .destructive) { delete(match) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { match in
                Text(deleteWarning(for: match))
            }
        }
    }

    /// Deleting a matchday cascades its fines, which quietly rewrites the season
    /// pot — including money already collected. Say so before doing it.
    private func deleteWarning(for match: Match) -> String {
        let count = match.fines.count
        guard count > 0 else { return "There are no fines on this matchday." }
        let collected = match.fines.filter(\.isPaid).reduce(0) { $0 + $1.amountPence }
        var text = "This also deletes \(count) fine\(count == 1 ? "" : "s") worth \(Money.string(match.total))."
        if collected > 0 {
            text += " \(Money.string(collected)) of that is already marked paid."
        }
        return text + " This can't be undone."
    }

    private func delete(_ match: Match) {
        context.delete(match)
        try? context.save()
        pendingDelete = nil
        Haptics.bump()
    }
}

private struct MatchRow: View {
    let match: Match

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(match.opponent)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                HStack(spacing: 6) {
                    if match.isComplete {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Text(match.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    if !match.itemOfTheWeek.isEmpty {
                        Text("·")
                        Text("Item: \(match.itemOfTheWeek)")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                // What's left to collect, not what was fined — a settled
                // matchday drops to £0 so there's nothing to chase.
                Text(Money.string(match.outstanding))
                    .font(.tally(20, .bold))
                    .foregroundStyle(match.outstanding > 0 ? Theme.accent : Theme.textFaint)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: match.outstanding)
                caption
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    @ViewBuilder
    private var caption: some View {
        if match.fines.isEmpty {
            Text("No fines")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
        } else if match.outstanding == 0 {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                Text("\(Money.string(match.total)) all in")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim)
        } else {
            Text("left of \(Money.string(match.total)) · \(match.fines.count) fine\(match.fines.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
    }
}

struct NewMatchSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.teamSession) private var session
    let players: [Player]

    @State private var opponent = ""
    @State private var date = Date()
    @State private var itemOfTheWeek = ""
    @FocusState private var opponentFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Opponent")
                        TextField("", text: $opponent, prompt: Text("e.g. Crown FC").foregroundStyle(Theme.textFaint))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.beige)
                            .textInputAutocapitalization(.words)
                            .focused($opponentFocused)
                            .padding(16)
                            .cardSurface()
                            .onSubmit(save)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Date")
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel(text: "Item of the week")
                            Spacer()
                            Text("optional")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textFaint)
                        }
                        TextField("", text: $itemOfTheWeek,
                                  prompt: Text("e.g. Traffic cone").foregroundStyle(Theme.textFaint))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.beige)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                            .padding(16)
                            .cardSurface()
                            .onSubmit(save)
                    }

                    Button("Start matchday", action: save)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(opponent.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("New matchday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textDim)
                }
            }
        }
        .presentationBackground(Theme.bg)
        .onAppear { opponentFocused = true }
    }

    private func save() {
        let name = opponent.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(Match(
            opponent: name,
            date: date,
            itemOfTheWeek: itemOfTheWeek.trimmingCharacters(in: .whitespaces),
            teamId: session.team?.id
        ))
        try? context.save()
        Haptics.bump()
        dismiss()
    }
}
