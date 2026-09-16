import SwiftUI

struct SettingsView: View {
    let auth: AuthService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.teamSession) private var session
    @Environment(\.teamDataStore) private var store
    @Environment(\.modelContext) private var context
    @State private var showingTeam = false
    @State private var deletion: AccountDeletionFlow?
    @AppStorage(Club.storageKey) private var storedClubName = ""
    @AppStorage(Club.closingKey) private var storedClosing = Club.defaultClosing

    @State private var name = ""
    @State private var closing = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { !trimmed.isEmpty }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Team")
                        Button { showingTeam = true } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.team?.name ?? Club.fallbackName)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(Theme.beige)
                                    Text("\(session.members.count) of \(TeamRules.maxMembers) members")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textDim)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textDim)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .cardSurface()
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Club name")
                        TextField("", text: $name, prompt: Text("e.g. Minety FC").foregroundStyle(Theme.textFaint))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.beige)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focused)
                            .padding(16)
                            .cardSurface()
                            .onSubmit(save)
                        Text("Shown on the season pot card.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textDim)
                            .padding(.horizontal, 2)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Share sign-off")
                        TextField("", text: $closing, axis: .vertical)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.beige)
                            .lineLimit(2...3)
                            .padding(16)
                            .cardSurface()
                        Text("The last line of every shared summary.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textDim)
                            .padding(.horizontal, 2)
                    }

                    Button("Save", action: save)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(!isValid)

                    Button("Sign out") {
                        Task {
                            await auth.signOut()
                            dismiss()
                        }
                    }
                    .buttonStyle(QuietButtonStyle())

                    Text(version)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    dangerZone
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textDim)
                }
            }
        }
        .presentationBackground(Theme.bg)
        .sheet(isPresented: $showingTeam) { TeamSettingsView().environment(\.teamSession, session) }
        .sheet(item: $deletion) { DeleteAccountView(flow: $0) }
        .onAppear {
            name = storedClubName
            closing = storedClosing
            focused = true
        }
    }

    /// Its own section at the bottom, one tap from here. Apple requires an
    /// app that creates accounts to let you delete one — guideline 5.1.1(v).
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Account")
            Button { deletion = makeDeletionFlow() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Delete account")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Theme.danger)
                .padding(16)
                .frame(maxWidth: .infinity)
                .cardSurface()
            }
            .buttonStyle(.plain)
            Text(deletionHint)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    /// Says up front which of the four situations applies, so the red button
    /// isn't a mystery box.
    private var deletionHint: String {
        switch deletionCase {
        case .handsOver(_, let successor):
            return "\(successor) would take the team over."
        case .deletesTeam(let team, _):
            return "You're the only member, so this deletes \(team) and everything in it."
        case .leavesTeam(let team):
            return "\(team) and its fines would stay with the owner."
        case .accountOnly:
            return "Permanently deletes your account."
        }
    }

    private var deletionCase: AccountDeletionCase {
        AccountDeletionCase.resolve(
            team: session.team,
            members: session.members,
            userId: auth.userId ?? "",
            contents: TeamContents(
                players: store.players.count,
                matches: store.matches.count,
                fines: store.fines.count
            )
        )
    }

    private func makeDeletionFlow() -> AccountDeletionFlow {
        AccountDeletionFlow(
            deletionCase: deletionCase,
            account: SupabaseAccountRepository(client: SupabaseClientProvider.shared),
            email: auth.email ?? ""
        ) { [context, session] in
            // The row is already gone server-side; leave nothing behind that a
            // relaunch could restore.
            LocalState.clear()
            LocalState.clearTeamStore(context)
            session.signedOut()
            await auth.signOut()
        }
    }

    private func save() {
        guard isValid else { return }
        storedClubName = trimmed
        storedClosing = closing.trimmingCharacters(in: .whitespacesAndNewlines)
        Haptics.bump()
        dismiss()
    }
}
