import SwiftUI

/// Shown whenever the signed-in user isn't a member of any team.
struct TeamOnboardingView: View {
    enum Mode: Hashable { case create, join }

    let auth: AuthService
    @Environment(\.teamSession) private var session

    @State private var mode: Mode?
    @State private var teamName = ""
    @State private var joinCode = ""
    @State private var displayName = ""
    @State private var error: String?
    @State private var busy = false
    @State private var deletion: AccountDeletionFlow?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PayUp")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Theme.beige)
                    Text("Set up your team, or join one someone's already made.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.top, 20)

                switch mode {
                case nil:
                    chooser
                case .create:
                    createForm
                case .join:
                    joinForm
                }

                // Without these there's no way off this screen for someone
                // signed in to the wrong account — and a Supabase session
                // outlives an app uninstall, so it happens.
                VStack(spacing: 14) {
                    Button("Sign out") { Task { await auth.signOut() } }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textDim)

                    // Someone who signs up and never makes a team still has an
                    // account, so deleting it has to be reachable from here —
                    // App Store guideline 5.1.1(v). Settings is behind a team.
                    Button("Delete account") { deletion = makeDeletionFlow() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.danger)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(20)
        }
        .screenBackground()
        .animation(.snappy(duration: 0.25), value: mode)
        .sheet(item: $deletion) { DeleteAccountView(flow: $0) }
    }

    /// No team here by definition, so this is always the account-only case —
    /// but it's resolved rather than assumed, so a stale session that does
    /// have a team can't be told the wrong thing.
    private func makeDeletionFlow() -> AccountDeletionFlow {
        AccountDeletionFlow(
            deletionCase: AccountDeletionCase.resolve(
                team: session.team,
                members: session.members,
                userId: auth.userId ?? ""
            ),
            account: SupabaseAccountRepository(client: SupabaseClientProvider.shared),
            email: auth.email ?? ""
        ) { [session] in
            LocalState.clear()
            session.signedOut()
            await auth.signOut()
        }
    }

    // MARK: - Chooser

    private var chooser: some View {
        VStack(spacing: 12) {
            option(
                icon: "flag.fill",
                title: "Create a team",
                detail: session.canCreateTeam
                    ? "You'll be the owner and get a code to invite one other person."
                    : limitExplanation,
                enabled: session.canCreateTeam
            ) { mode = .create }

            option(
                icon: "person.badge.plus",
                title: "Join with a code",
                detail: "Someone on your team has a six-character code."
            ) { mode = .join }
        }
    }

    /// Neutral and factual. There's nothing to sell yet, so no upgrade prompt.
    private var limitExplanation: String {
        let limit = session.entitlements.maxTeamsOwned
        return limit == 1
            ? "Free accounts can run one team. You already own one, so you can't create another, you can still join a team with a code."
            : "Your account can own up to \(limit) teams and you're at that limit. You can still join a team with a code."
    }

    private func option(
        icon: String,
        title: String,
        detail: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(enabled ? Theme.accent : Theme.textFaint)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(enabled ? Theme.beige : Theme.textDim)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(Theme.Radius.card)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Forms

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            field(label: "Team name", text: $teamName, prompt: "e.g. Minety FC")
            field(label: "Your name", text: $displayName, prompt: "e.g. Matt")
            errorLine

            Button(busy ? "Creating…" : "Create team") { submitCreate() }
                .buttonStyle(AccentButtonStyle())
                .disabled(busy || trimmed(teamName).isEmpty || trimmed(displayName).isEmpty)

            backButton
        }
    }

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Join code")
                TextField("", text: $joinCode, prompt: Text("ABC234").foregroundStyle(Theme.textFaint))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.beige)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(16)
                    .cardSurface()
                    .onChange(of: joinCode) { _, new in
                        let cleaned = JoinCode.normalise(new)
                        if cleaned != new { joinCode = cleaned }
                    }
            }
            field(label: "Your name", text: $displayName, prompt: "e.g. Matt")
            errorLine

            Button(busy ? "Joining…" : "Join team") { submitJoin() }
                .buttonStyle(AccentButtonStyle())
                .disabled(busy || joinCode.count < JoinCode.length || trimmed(displayName).isEmpty)

            backButton
        }
        .onAppear { focused = true }
    }

    private func field(label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: label)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.textFaint))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.beige)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(16)
                .cardSurface()
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error {
            Text(error)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: 0xFF6B6B))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var backButton: some View {
        Button("Back") {
            error = nil
            mode = nil
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Theme.textDim)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
    }

    private func submitCreate() {
        submit { try await session.createTeam(name: trimmed(teamName), displayName: trimmed(displayName)) }
    }

    private func submitJoin() {
        submit { try await session.joinTeam(code: joinCode, displayName: trimmed(displayName)) }
    }

    private func submit(_ work: @escaping () async throws -> Void) {
        error = nil
        busy = true
        Task {
            do {
                try await work()
                Haptics.bump()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
