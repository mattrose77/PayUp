import SwiftUI
import SwiftData

private struct TeamSessionKey: @preconcurrency EnvironmentKey {
    /// Never builds a container — see UnavailableTeamRepository.
    @MainActor
    static let defaultValue = TeamSession(
        repository: UnavailableTeamRepository(),
        userId: "",
        makeDataStore: { _, _ in TeamDataStoreKey.defaultValue }
    )
}

private struct TeamDataStoreKey: @preconcurrency EnvironmentKey {
    /// Placeholder only — the real store is injected once a team resolves.
    @MainActor
    static let defaultValue = TeamDataStore(
        teamId: UUID(), userId: "",
        players: LocalPlayerRepository(store: LocalStore()),
        fineTypes: LocalFineTypeRepository(store: LocalStore()),
        matches: LocalMatchRepository(store: LocalStore()),
        fines: LocalFineRepository(store: LocalStore())
    )
}

extension EnvironmentValues {
    var teamSession: TeamSession {
        get { self[TeamSessionKey.self] }
        set { self[TeamSessionKey.self] = newValue }
    }

    var teamDataStore: TeamDataStore {
        get { self[TeamDataStoreKey.self] }
        set { self[TeamDataStoreKey.self] = newValue }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context

    @State private var auth = AuthService(client: SupabaseClientProvider.shared)
    @State private var session: TeamSession?
    @State private var showSplash = true

    var body: some View {
        ZStack {
            content
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // Session building is left entirely to onChange below. Doing it
            // here as well ran two builds concurrently on a cold start, each
            // overwriting the other's session.
            await auth.restore()
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
        }
        .onChange(of: auth.state) { _, _ in
            Task { await buildSessionIfNeeded() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch auth.state {
        case .restoring:
            // Deliberately blank rather than the sign-in screen: flashing sign-in
            // at someone who is already signed in is the classic bug here.
            Theme.bg.ignoresSafeArea()

        case .signedOut:
            AuthView(auth: auth)

        case .signedIn:
            if let session {
                signedIn(session)
                    .environment(\.teamSession, session)
            } else {
                loading
            }
        }
    }

    /// Every branch is terminal except `.idle`/`.loading`, which only hold
    /// while a fetch is genuinely in flight. A failure lands on an error with
    /// a retry rather than a spinner that never resolves.
    @ViewBuilder
    private func signedIn(_ session: TeamSession) -> some View {
        switch session.phase {
        case .idle, .loading:
            loading
        case .needsTeam:
            TeamOnboardingView(auth: auth)
        case .ready:
            if let store = session.dataStore {
                MainTabView(auth: auth).environment(\.teamDataStore, store)
            } else {
                // Unreachable: `.ready` is only set once the store is built.
                failed("The team loaded but its data didn't.")
            }
        case .failed(let message):
            failed(message)
        }
    }

    private func failed(_ message: String) -> some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ErrorStateView(message: message) {
                Task { await session?.refresh() }
            }
            .padding(20)
        }
    }

    private var loading: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ProgressView().tint(Theme.accent)
        }
    }

    private func buildSessionIfNeeded() async {
        guard case .signedIn(let userId, _) = auth.state else {
            session?.signedOut()
            session = nil
            return
        }

        if let session {
            session.adopt(userId: userId)
        } else {
            // Nothing is seeded: every club's fines list differs, and a wrong
            // default is worse than an empty list with a good empty state.
            session = TeamSession(
                repository: SupabaseTeamRepository(client: SupabaseClientProvider.shared),
                userId: userId,
                makeDataStore: Self.makeSupabaseDataStore
            )
        }

        // The store is built inside refresh(), alongside the team it belongs
        // to, so joining or creating one rebuilds it too.
        await session?.refresh()
    }

    /// A fresh store per team — never reused across accounts or teams.
    @MainActor
    private static func makeSupabaseDataStore(teamId: UUID, userId: String) -> TeamDataStore {
        let client = SupabaseClientProvider.shared
        return TeamDataStore(
            teamId: teamId,
            userId: userId,
            players: SupabasePlayerRepository(client: client),
            fineTypes: SupabaseFineTypeRepository(client: client),
            matches: SupabaseMatchRepository(client: client),
            fines: SupabaseFineRepository(client: client)
        )
    }
}

struct MainTabView: View {
    let auth: AuthService

    var body: some View {
        TabView {
            MatchesView(auth: auth)
                .tabItem { Label("Matches", systemImage: "sportscourt.fill") }
            ShameBoardView()
                .tabItem { Label("Shame", systemImage: "flame.fill") }
            SquadView()
                .tabItem { Label("Squad", systemImage: "person.2.fill") }
            FineTypesView()
                .tabItem { Label("Fines", systemImage: "sterlingsign.circle.fill") }
        }
    }
}
