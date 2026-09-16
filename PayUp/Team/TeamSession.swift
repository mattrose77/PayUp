import Foundation
import SwiftData
import Observation

/// The signed-in user's current team, kept in the environment.
@MainActor
@Observable
final class TeamSession {
    /// Where the app is for this account. Every async entry point drives this
    /// to a terminal case — `.needsTeam`, `.ready` or `.failed` — so an
    /// indefinite spinner isn't a reachable state.
    enum Phase: Equatable {
        case idle
        case loading
        /// Signed in, no team yet: onboarding.
        case needsTeam
        /// Team resolved and `dataStore` is built for it.
        case ready
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .idle, .loading: return false
            case .needsTeam, .ready, .failed: return true
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var team: Team?
    private(set) var members: [TeamMember] = []

    /// Owned here rather than by the view, because it's derived from `team` and
    /// has to be rebuilt the moment the team changes. Keeping it in RootView
    /// meant joining a team never built one, and the app sat on a spinner.
    private(set) var dataStore: TeamDataStore?

    var hasLoaded: Bool { phase.isTerminal }

    /// Display snapshot only, refreshed whenever team state changes. The
    /// authority is the repository, which recomputes the count on every create,
    /// and ultimately the database trigger.
    private(set) var ownedTeamCount = 0

    private let repository: TeamRepository
    private var userId: String
    /// Injected so tests can build a store over the in-memory repositories.
    private let makeDataStore: (UUID, String) -> TeamDataStore

    init(
        repository: TeamRepository,
        userId: String = CurrentUser.id,
        makeDataStore: @escaping (UUID, String) -> TeamDataStore
    ) {
        self.repository = repository
        self.userId = UserID.normalise(userId)
        self.makeDataStore = makeDataStore
    }

    var currentMember: TeamMember? { members.first { UserID.matches($0.userId, userId) } }
    var isOwner: Bool { currentMember?.role == .owner }
    var isFull: Bool { members.count >= TeamRules.maxMembers }

    var entitlements: Entitlements { repository.entitlements }
    var canCreateTeam: Bool { ownedTeamCount < entitlements.maxTeamsOwned }

    /// Called when auth resolves to a different account. The store goes with
    /// it — a store is scoped to one team of one account, never reused.
    func adopt(userId: String) {
        self.userId = UserID.normalise(userId)
        team = nil
        members = []
        dataStore = nil
        ownedTeamCount = 0
        phase = .idle
    }

    func signedOut() {
        adopt(userId: "")
        phase = .needsTeam
    }

    /// Taking the first is the only place single-team is assumed, and it's a
    /// one-line change to present a picker instead.
    ///
    /// Errors surface as `.failed` rather than being swallowed: a fetch that
    /// fails used to look identical to "you have no team", which would invite
    /// someone with a team to create a second one.
    func refresh() async {
        guard !userId.isEmpty else {
            apply(team: nil, members: [])
            ownedTeamCount = 0
            return
        }

        phase = .loading
        do {
            let teams = try await repository.teams(forUser: userId)
            let current = teams.first
            var roster: [TeamMember] = []
            if let current {
                roster = try await repository.members(of: current.id)
            }

            // Removed from the team while the app was open: drop back to
            // onboarding rather than showing a team you're not part of.
            if current != nil, !roster.contains(where: { UserID.matches($0.userId, userId) }) {
                apply(team: nil, members: [])
            } else {
                apply(team: current, members: roster)
            }

            ownedTeamCount = try await repository.ownedTeamCount(forUser: userId)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The one place `team` is set, so the store can never drift from it.
    private func apply(team: Team?, members: [TeamMember]) {
        self.team = team
        self.members = members

        guard let team else {
            dataStore = nil
            phase = .needsTeam
            return
        }
        if dataStore?.teamId != team.id {
            dataStore = makeDataStore(team.id, userId)
        }
        phase = .ready

        if !team.name.isEmpty {
            UserDefaults.standard.set(team.name, forKey: Club.storageKey)
        }
    }

    // MARK: - Mutations

    func createTeam(name: String, displayName: String) async throws {
        CurrentUser.displayName = displayName
        let team = try await repository.createTeam(
            name: name, userId: userId, displayName: displayName
        )
        await refresh()
        onTeamCreated?(team)
    }

    func joinTeam(code: String, displayName: String) async throws {
        CurrentUser.displayName = displayName
        _ = try await repository.joinTeam(code: code, userId: userId, displayName: displayName)
        await refresh()
    }

    func rename(to name: String) async throws {
        guard let team else { return }
        try await repository.rename(teamId: team.id, to: name)
        await refresh()
    }

    func regenerateJoinCode() async throws {
        guard let team else { return }
        _ = try await repository.regenerateJoinCode(teamId: team.id, by: userId)
        await refresh()
    }

    func remove(_ member: TeamMember) async throws {
        try await repository.removeMember(member.id, by: userId)
        await refresh()
    }

    func leave() async throws {
        guard let team else { return }
        try await repository.leaveTeam(teamId: team.id, userId: userId)
        await refresh()
    }

    /// Hook so a brand new team gets the default fine list.
    var onTeamCreated: ((Team) -> Void)?
}
