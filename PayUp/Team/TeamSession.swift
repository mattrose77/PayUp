import Foundation
import SwiftData
import Observation

/// The signed-in user's current team, kept in the environment.
@MainActor
@Observable
final class TeamSession {
    private(set) var team: Team?
    private(set) var members: [TeamMember] = []
    private(set) var hasLoaded = false

    /// Display snapshot only, refreshed whenever team state changes. The
    /// authority is the repository, which recomputes the count on every create,
    /// and ultimately the database trigger.
    private(set) var ownedTeamCount = 0

    private let repository: TeamRepository
    private var userId: String

    init(repository: TeamRepository, userId: String = CurrentUser.id) {
        self.repository = repository
        self.userId = UserID.normalise(userId)
    }

    var currentMember: TeamMember? { members.first { UserID.matches($0.userId, userId) } }
    var isOwner: Bool { currentMember?.role == .owner }
    var isFull: Bool { members.count >= TeamRules.maxMembers }

    var entitlements: Entitlements { repository.entitlements }
    var canCreateTeam: Bool { ownedTeamCount < entitlements.maxTeamsOwned }

    /// Called when auth resolves to a different account.
    func adopt(userId: String) {
        self.userId = UserID.normalise(userId)
        team = nil
        members = []
        ownedTeamCount = 0
        hasLoaded = false
    }

    func signedOut() {
        adopt(userId: "")
        hasLoaded = true
    }

    /// Taking the first is the only place single-team is assumed, and it's a
    /// one-line change to present a picker instead.
    func refresh() async {
        guard !userId.isEmpty else {
            team = nil
            members = []
            ownedTeamCount = 0
            hasLoaded = true
            return
        }

        let teams = (try? await repository.teams(forUser: userId)) ?? []
        let current = teams.first
        var roster: [TeamMember] = []
        if let current {
            roster = (try? await repository.members(of: current.id)) ?? []
        }

        // Removed from the team while the app was open: drop back to onboarding
        // rather than showing a team the user is no longer part of.
        if current != nil, !roster.contains(where: { UserID.matches($0.userId, userId) }) {
            team = nil
            members = []
        } else {
            team = current
            members = roster
        }

        ownedTeamCount = (try? await repository.ownedTeamCount(forUser: userId)) ?? 0
        hasLoaded = true

        if let name = team?.name, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: Club.storageKey)
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
