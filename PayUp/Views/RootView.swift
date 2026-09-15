import SwiftUI
import SwiftData

private struct TeamSessionKey: @preconcurrency EnvironmentKey {
    /// Never builds a container — see UnavailableTeamRepository.
    @MainActor
    static let defaultValue = TeamSession(repository: UnavailableTeamRepository(), userId: "")
}

extension EnvironmentValues {
    var teamSession: TeamSession {
        get { self[TeamSessionKey.self] }
        set { self[TeamSessionKey.self] = newValue }
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
            LaunchMigration.migrateMoneyToPence(context)
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
                        TeamOnboardingView()
                    } else {
                        MainTabView(auth: auth)
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
            return
        }

        if session == nil {
            let repository = SupabaseTeamRepository(client: SupabaseClientProvider.shared)
            let built = TeamSession(repository: repository, userId: userId)
            built.onTeamCreated = { team in
                SeedData.seedFines(for: team.id, in: context)
            }
            session = built
        } else {
            session?.adopt(userId: userId)
        }

        await session?.refresh()
        if let teamId = session?.team?.id {
            // Local players/matches/fines predate teams; attach them once we know
            // which team this account belongs to.
            LaunchMigration.adoptOrphans(context, into: teamId)
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
