import SwiftUI
import SwiftData

private struct TeamSessionKey: @preconcurrency EnvironmentKey {
    /// Never builds a container — see UnavailableTeamRepository.
    @MainActor
    static let defaultValue = TeamSession(repository: UnavailableTeamRepository(), userId: "")
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
    @State private var dataStore: TeamDataStore?
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
            await auth.restore()
            await buildSessionIfNeeded()
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
            if let session, session.hasLoaded {
                Group {
                    if session.team == nil {
                        TeamOnboardingView(auth: auth)
                    } else if let dataStore {
                        MainTabView(auth: auth)
                            .environment(\.teamDataStore, dataStore)
                    } else {
                        loading
                    }
                }
                .environment(\.teamSession, session)
            } else {
                loading
            }
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
            dataStore = nil
            return
        }

        if session == nil {
            let repository = SupabaseTeamRepository(client: SupabaseClientProvider.shared)
            let built = TeamSession(repository: repository, userId: userId)
            // Nothing is seeded: every club's fines list differs, and a wrong
            // default is worse than an empty list with a good empty state.
            session = built
        } else {
            session?.adopt(userId: userId)
        }

        await session?.refresh()
        rebuildDataStore(userId: userId)
    }

    /// A fresh store per team — never reuse one across accounts or teams.
    private func rebuildDataStore(userId: String) {
        guard let teamId = session?.team?.id else {
            dataStore = nil
            return
        }
        if dataStore == nil {
            let client = SupabaseClientProvider.shared
            dataStore = TeamDataStore(
                teamId: teamId,
                userId: userId,
                players: SupabasePlayerRepository(client: client),
                fineTypes: SupabaseFineTypeRepository(client: client),
                matches: SupabaseMatchRepository(client: client),
                fines: SupabaseFineRepository(client: client)
            )
        }
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
