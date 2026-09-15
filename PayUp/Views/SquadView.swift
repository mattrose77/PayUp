import SwiftUI
import SwiftData

struct SquadView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.teamSession) private var session
    @Query(sort: [SortDescriptor(\Player.name)]) private var allPlayers: [Player]

    private var players: [Player] { allPlayers.scoped(to: session.team?.id) }

    @State private var newName = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ScreenHeader(title: "Squad", subtitle: "\(players.count) player\(players.count == 1 ? "" : "s")")

                    addField

                    if players.isEmpty {
                        EmptyHint(
                            icon: "person.2",
                            title: "Build the squad",
                            message: "Type a name above and hit return. Keep going — the field stays put."
                        )
                        .cardSurface(Theme.Radius.card)
                    } else {
                        ForEach(players) { player in
                            NavigationLink {
                                PlayerDetailView(player: player)
                            } label: {
                                SquadRow(player: player)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { delete(player) } label: {
                                    Label("Remove from squad", systemImage: "trash")
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
        }
    }

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
                .submitLabel(.done)
                .focused($addFocused)
                .onSubmit(add)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardSurface()
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let order = (players.map(\.rotaOrder).max() ?? -1) + 1
        context.insert(Player(name: name, rotaOrder: order, teamId: session.team?.id))
        try? context.save()
        newName = ""
        addFocused = true
        Haptics.tap()
    }

    private func delete(_ player: Player) {
        context.delete(player)
        try? context.save()
    }
}

private struct SquadRow: View {
    let player: Player

    var body: some View {
        HStack(spacing: 13) {
            Avatar(initials: player.initials, size: 40, highlighted: false)

            VStack(alignment: .leading, spacing: 3) {
                Text(player.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                Text(player.fines.isEmpty
                     ? "No fines"
                     : "\(player.fines.count) fine\(player.fines.count == 1 ? "" : "s") · \(Money.string(player.totalFined))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 6)

            if player.balance > 0 {
                Text("owes \(Money.string(player.balance))")
                    .font(.tally(13, .bold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            } else if !player.fines.isEmpty {
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
