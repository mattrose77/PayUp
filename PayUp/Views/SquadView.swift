import SwiftUI

struct SquadView: View {
    @Environment(\.teamDataStore) private var store

    @State private var newName = ""
    @State private var queue: RapidEntryQueue<String>?
    @State private var warning: String?
    @State private var error: String?
    @State private var pendingRemoval: Player?
    @FocusState private var addFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ScreenHeader(
                        title: "Squad",
                        subtitle: store.state == .loaded
                            ? "\(store.activePlayers.count) active"
                            : "Your players"
                    )

                    DataStateContainer(state: store.state, refreshError: store.refreshError, retry: { await store.refresh() }) {
                        addField

                        if let warning {
                            Text(warning)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        // Submission order, never rearranged by whichever save
                        // happens to land first.
                        ForEach(queue?.visibleDrafts ?? []) { draft in
                            PendingRow(
                                title: draft.payload,
                                detail: nil,
                                state: draft.state,
                                retry: { queue?.retry(draft.id) },
                                discard: { queue?.discard(draft.id) }
                            )
                        }

                        if let error {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: 0xFF6B6B))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        if store.players.isEmpty && (queue?.visibleDrafts.isEmpty ?? true) {
                            EmptyStateView(
                                icon: "person.2",
                                title: "No players yet",
                                message: "Players are the people who get fined. Add everyone who turns out for the team — you can make them inactive later if they stop playing.",
                                actionTitle: "Add player",
                                action: { addFocused = true }
                            )
                        } else {
                            ForEach(store.players) { player in
                                NavigationLink {
                                    PlayerDetailView(playerId: player.id)
                                } label: {
                                    SquadRow(player: player, fines: store.fines(forPlayer: player.id))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { menu(for: player) }
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
            .alert(
                pendingRemoval.map { "Remove \($0.name)?" } ?? "",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                presenting: pendingRemoval
            ) { player in
                Button("Remove", role: .destructive) { remove(player) }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { player in
                Text(removalMessage(for: player))
            }
        }
    }

    @ViewBuilder
    private func menu(for player: Player) -> some View {
        if player.active {
            Button { pendingRemoval = player } label: {
                Label("Remove from squad", systemImage: "person.badge.minus")
            }
        } else {
            Button { setActive(player, true) } label: {
                Label("Make active again", systemImage: "arrow.uturn.backward")
            }
        }
    }

    /// A player with history can't be deleted — the FK is restrict — so the
    /// action means something different depending on whether they have fines.
    private func removalMessage(for player: Player) -> String {
        let count = store.fines(forPlayer: player.id).count
        guard count > 0 else {
            return "They have no fines on record, so they'll be deleted outright."
        }
        let owed = store.fines(forPlayer: player.id).outstandingPence
        var text = "They have \(count) fine\(count == 1 ? "" : "s") on record, so they'll be made inactive instead of deleted. Their history stays"
        text += owed > 0 ? " and they still owe \(Money.string(owed))." : "."
        return text + " They won't appear on new matchdays."
    }

    /// Never disabled, never loses focus — the whole point is that entering a
    /// squad feels like typing a list, not filling in fourteen forms.
    private var addField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
            TextField("", text: $newName, prompt: Text("Add player").foregroundStyle(Theme.textFaint))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.beige)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($addFocused)
                .onSubmit(add)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardSurface()
    }

    private func add() {
        guard let name = EntryValidation.cleanName(newName) else {
            // Whitespace only — clear it and carry on without a network call.
            newName = ""
            addFocused = true
            return
        }
        warning = EntryValidation.duplicateWarning(
            for: name, existing: store.players.map(\.name)
        )
        // Clear immediately so the next name can be typed straight away.
        newName = ""
        addFocused = true
        Haptics.tap()
        ensureQueue().submit(name)
    }

    private func ensureQueue() -> RapidEntryQueue<String> {
        if let queue { return queue }
        let created = RapidEntryQueue<String> { name in
            try await store.addPlayer(name: name)
        }
        queue = created
        return created
    }

    private func remove(_ player: Player) {
        pendingRemoval = nil
        error = nil
        Task {
            do {
                if store.fines(forPlayer: player.id).isEmpty {
                    try await store.deletePlayer(player)
                } else {
                    try await store.setPlayerActive(player, active: false)
                }
                Haptics.bump()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func setActive(_ player: Player, _ active: Bool) {
        error = nil
        Task {
            do { try await store.setPlayerActive(player, active: active) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct SquadRow: View {
    let player: Player
    let fines: [Fine]

    var body: some View {
        HStack(spacing: 13) {
            Avatar(initials: player.initials, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(player.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(player.active ? Theme.beige : Theme.textDim)
                    if !player.active {
                        Text("INACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceHi, in: Capsule())
                    }
                }
                Text(fines.isEmpty
                     ? "No fines"
                     : "\(fines.count) fine\(fines.count == 1 ? "" : "s") · \(Money.string(fines.totalPence))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 6)

            if fines.outstandingPence > 0 {
                Text("owes \(Money.string(fines.outstandingPence))")
                    .font(.tally(13, .bold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            } else if !fines.isEmpty {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}
