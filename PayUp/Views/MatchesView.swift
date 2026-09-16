import SwiftUI

struct MatchesView: View {
    let auth: AuthService
    @Environment(\.teamDataStore) private var store

    @State private var showingNewMatch = false
    @State private var showingSettings = false
    @State private var pendingDelete: Match?
    @State private var error: String?

    private var canStartMatchday: Bool {
        !store.activePlayers.isEmpty && !store.activeFineTypes.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ScreenHeader(title: "PayUp", subtitle: "Matchday fines") {
                        HStack(spacing: 10) {
                            HeaderIconButton(systemName: "gearshape.fill") { showingSettings = true }
                            if !store.matches.isEmpty {
                                HeaderAddButton(enabled: canStartMatchday) { showingNewMatch = true }
                            }
                        }
                    }

                    DataStateContainer(state: store.state, retry: { await store.refresh() }) {
                        SeasonPotCard(stats: store.seasonStats)
                            .padding(.bottom, 6)

                        if let error {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: 0xFF6B6B))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        if store.matches.isEmpty {
                            emptyState
                        } else {
                            HStack {
                                SectionLabel(text: "Matchdays")
                                Spacer()
                                Text("\(store.matches.count)")
                                    .font(.tally(12, .bold))
                                    .foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 4)

                            ForEach(store.matches) { match in
                                NavigationLink {
                                    TallyView(matchId: match.id).environment(\.teamDataStore, store)
                                } label: {
                                    MatchRow(match: match, fines: store.fines(forMatch: match.id))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) { pendingDelete = match } label: {
                                        Label("Delete matchday", systemImage: "trash")
                                    }
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
            .sheet(isPresented: $showingNewMatch) {
                NewMatchSheet().environment(\.teamDataStore, store)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(auth: auth).environment(\.teamDataStore, store)
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

    /// A matchday needs players to fine and fines to give them, so say which
    /// is missing rather than offering a dead button.
    @ViewBuilder
    private var emptyState: some View {
        if store.activePlayers.isEmpty || store.activeFineTypes.isEmpty {
            EmptyStateView(
                icon: "sportscourt",
                title: "Set up first",
                message: setupMessage
            )
        } else {
            EmptyStateView(
                icon: "sportscourt",
                title: "No matchdays yet",
                message: "A matchday is where fines get logged — pick an offence, tap whoever earned it. Start one after a game.",
                actionTitle: "Start a matchday",
                action: { showingNewMatch = true }
            )
        }
    }

    private var setupMessage: String {
        let noPlayers = store.activePlayers.isEmpty
        let noFines = store.activeFineTypes.isEmpty
        if noPlayers && noFines {
            return "A matchday needs a squad to fine and a list of offences to fine them for. Add some players in the Squad tab and build your fines list in the Fines tab, then come back."
        }
        if noPlayers {
            return "You've got your fines list, but nobody to give them to. Add your squad in the Squad tab first."
        }
        return "You've got a squad, but no offences to fine them for. Build your fines list in the Fines tab first."
    }

    private func deleteWarning(for match: Match) -> String {
        let fines = store.fines(forMatch: match.id)
        guard !fines.isEmpty else { return "There are no fines on this matchday." }
        let paid = fines.paidPence
        var text = "This also deletes \(fines.count) fine\(fines.count == 1 ? "" : "s") worth \(Money.string(fines.totalPence))."
        if paid > 0 { text += " \(Money.string(paid)) of that is already marked paid." }
        return text + " This can't be undone."
    }

    private func delete(_ match: Match) {
        pendingDelete = nil
        error = nil
        Task {
            do {
                try await store.deleteMatch(match)
                Haptics.bump()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct MatchRow: View {
    let match: Match
    let fines: [Fine]

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
                    Text(match.playedOn, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    if !match.itemOfTheWeek.isEmpty {
                        Text("·")
                        Text("Item: \(match.itemOfTheWeek)").lineLimit(1)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Money.string(fines.outstandingPence))
                    .font(.tally(20, .bold))
                    .foregroundStyle(fines.outstandingPence > 0 ? Theme.accent : Theme.textFaint)
                caption
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    @ViewBuilder
    private var caption: some View {
        if fines.isEmpty {
            Text("No fines").font(.system(size: 12)).foregroundStyle(Theme.textDim)
        } else if fines.outstandingPence == 0 {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
                Text("\(Money.string(fines.totalPence)) all in")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim)
        } else {
            Text("left of \(Money.string(fines.totalPence)) · \(fines.count) fine\(fines.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
    }
}

struct NewMatchSheet: View {
    @Environment(\.teamDataStore) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var opponent = ""
    @State private var date = Date()
    @State private var itemOfTheWeek = ""
    @State private var busy = false
    @State private var error: String?
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
                            Text("optional").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                        }
                        TextField("", text: $itemOfTheWeek,
                                  prompt: Text("e.g. Traffic cone").foregroundStyle(Theme.textFaint))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.beige)
                            .textInputAutocapitalization(.sentences)
                            .padding(16)
                            .cardSurface()
                            .onSubmit(save)
                    }

                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B))
                    }

                    Button(busy ? "Starting…" : "Start matchday", action: save)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(busy || opponent.trimmingCharacters(in: .whitespaces).isEmpty)
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
        busy = true
        error = nil
        Task {
            do {
                _ = try await store.addMatch(
                    opponent: name,
                    playedOn: date,
                    itemOfTheWeek: itemOfTheWeek.trimmingCharacters(in: .whitespaces)
                )
                Haptics.bump()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
