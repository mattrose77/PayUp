import Foundation
import SwiftData

enum TeamError: LocalizedError, Equatable {
    case teamFull
    case codeNotFound
    case alreadyMember
    case notAuthorised
    case ownerCannotLeave
    case teamLimitReached(limit: Int)
    /// Anything the server rejected that this client doesn't recognise. Keeps a
    /// new server-side rule from crashing an old build.
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .teamFull:
            return "That team already has both its members."
        case .codeNotFound:
            return "No team found with that code."
        case .alreadyMember:
            return "You're already in this team."
        case .notAuthorised:
            return "You don't have permission to do that."
        case .ownerCannotLeave:
            return "The owner can't leave their own team."
        case .serverRejected(let message):
            return message
        case .teamLimitReached(let limit):
            return limit == 1
                ? "Free accounts can run one team, and you already own one."
                : "Your account can own up to \(limit) teams."
        }
    }
}

/// Every team/member read and write goes through here so a Supabase-backed
/// implementation can replace the local one without views changing.
protocol TeamRepository {
    /// What this account is allowed to do. Callers read limits from here rather
    /// than knowing any numbers themselves.
    var entitlements: Entitlements { get }

    /// Live count of teams where this user holds `.owner`. Never cached: a
    /// deleted team has to free its slot immediately.
    func ownedTeamCount(forUser userId: String) async throws -> Int

    /// Plural on purpose — one team per user today, but nothing assumes it.
    func teams(forUser userId: String) async throws -> [Team]
    func members(of teamId: UUID) async throws -> [TeamMember]

    func createTeam(name: String, userId: String, displayName: String) async throws -> Team
    func joinTeam(code: String, userId: String, displayName: String) async throws -> Team

    func rename(teamId: UUID, to name: String) async throws
    func regenerateJoinCode(teamId: UUID, by userId: String) async throws -> String

    func removeMember(_ memberId: UUID, by userId: String) async throws
    func leaveTeam(teamId: UUID, userId: String) async throws
    func deleteTeam(teamId: UUID, by userId: String) async throws
}

/// Cap lives here rather than in the views. The server will enforce it too.
enum TeamRules {
    static let maxMembers = 2
}

// NOTE: every check in this file is advisory. A determined client can bypass
// all of it. The authoritative limits will be a Postgres trigger on
// team_members — both the two-member cap and the owned-team entitlement — so
// these exist to give a good error message, not to secure anything.

struct LocalTeamRepository: TeamRepository {
    let context: ModelContext
    var entitlementsProvider: EntitlementsProvider = FreeEntitlementsProvider()

    var entitlements: Entitlements { entitlementsProvider.current }

    // MARK: - Reads

    func teams(forUser userId: String) async throws -> [Team] {
        let memberships = try context.fetch(
            FetchDescriptor<TeamMember>(predicate: #Predicate { $0.userId == userId })
        )
        let ids = Set(memberships.map(\.teamId))
        guard !ids.isEmpty else { return [] }
        let all = try context.fetch(FetchDescriptor<Team>())
        return all.filter { ids.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }

    func ownedTeamCount(forUser userId: String) async throws -> Int {
        let ownerRole = TeamRole.owner.rawValue
        let owned = try context.fetch(
            FetchDescriptor<TeamMember>(
                predicate: #Predicate { $0.userId == userId && $0.roleRaw == ownerRole }
            )
        )
        guard !owned.isEmpty else { return 0 }
        // Join against live teams so a deleted team frees its slot even if a
        // membership row were ever left behind.
        let liveIds = Set(try context.fetch(FetchDescriptor<Team>()).map(\.id))
        return owned.filter { liveIds.contains($0.teamId) }.count
    }

    func members(of teamId: UUID) async throws -> [TeamMember] {
        try context.fetch(
            FetchDescriptor<TeamMember>(predicate: #Predicate { $0.teamId == teamId })
        )
        .sorted { $0.joinedAt < $1.joinedAt }
    }

    // MARK: - Joining

    func createTeam(name: String, userId: String, displayName: String) async throws -> Team {
        let limit = entitlements.maxTeamsOwned
        guard try await ownedTeamCount(forUser: userId) < limit else {
            throw TeamError.teamLimitReached(limit: limit)
        }
        let team = Team(name: name, joinCode: try uniqueCode())
        context.insert(team)
        context.insert(
            TeamMember(teamId: team.id, userId: userId, displayName: displayName, role: .owner)
        )
        try context.save()
        return team
    }

    func joinTeam(code: String, userId: String, displayName: String) async throws -> Team {
        let wanted = JoinCode.normalise(code)
        let teams = try context.fetch(FetchDescriptor<Team>())
        guard let team = teams.first(where: { $0.joinCode == wanted }) else {
            throw TeamError.codeNotFound
        }
        let existing = try await members(of: team.id)
        if existing.contains(where: { UserID.matches($0.userId, userId) }) { throw TeamError.alreadyMember }
        guard existing.count < TeamRules.maxMembers else { throw TeamError.teamFull }

        // No entitlement check: joining as .admin never counts toward
        // maxTeamsOwned, so you can own your own team and help run a mate's.
        context.insert(
            TeamMember(teamId: team.id, userId: userId, displayName: displayName, role: .admin)
        )
        try context.save()
        return team
    }

    // MARK: - Team admin

    func rename(teamId: UUID, to name: String) async throws {
        guard let team = try team(teamId) else { return }
        team.name = name
        try context.save()
    }

    func regenerateJoinCode(teamId: UUID, by userId: String) async throws -> String {
        guard let team = try team(teamId) else { throw TeamError.codeNotFound }
        let roster = try await members(of: teamId)
        guard roster.first(where: { UserID.matches($0.userId, userId) })?.role == .owner else {
            throw TeamError.notAuthorised
        }
        let fresh = try uniqueCode()
        team.joinCode = fresh
        try context.save()
        return fresh
    }

    // MARK: - Membership changes

    func removeMember(_ memberId: UUID, by userId: String) async throws {
        let all = try context.fetch(
            FetchDescriptor<TeamMember>(predicate: #Predicate { $0.id == memberId })
        )
        guard let target = all.first else { return }
        guard target.role != .owner else { throw TeamError.notAuthorised }

        let roster = try await members(of: target.teamId)
        guard roster.first(where: { UserID.matches($0.userId, userId) })?.role == .owner else {
            throw TeamError.notAuthorised
        }
        // The team's players, matches and fines are untouched — they belong to
        // the team, not to whoever happened to be logging them.
        context.delete(target)
        try context.save()
    }

    func leaveTeam(teamId: UUID, userId: String) async throws {
        let roster = try await members(of: teamId)
        guard let me = roster.first(where: { UserID.matches($0.userId, userId) }) else { return }
        guard me.role != .owner else { throw TeamError.ownerCannotLeave }
        context.delete(me)
        try context.save()
    }

    func deleteTeam(teamId: UUID, by userId: String) async throws {
        let roster = try await members(of: teamId)
        guard roster.first(where: { UserID.matches($0.userId, userId) })?.role == .owner else {
            throw TeamError.notAuthorised
        }
        for member in roster { context.delete(member) }
        for player in try context.fetch(FetchDescriptor<Player>()).scoped(to: teamId) {
            context.delete(player)
        }
        for match in try context.fetch(FetchDescriptor<Match>()).scoped(to: teamId) {
            context.delete(match)
        }
        for type in try context.fetch(FetchDescriptor<FineType>()).scoped(to: teamId) {
            context.delete(type)
        }
        if let team = try team(teamId) { context.delete(team) }
        try context.save()
    }

    // MARK: - Helpers

    private func team(_ id: UUID) throws -> Team? {
        try context.fetch(FetchDescriptor<Team>(predicate: #Predicate { $0.id == id })).first
    }

    private func uniqueCode() throws -> String {
        let taken = Set(try context.fetch(FetchDescriptor<Team>()).map(\.joinCode))
        for _ in 0..<50 {
            let candidate = JoinCode.generate()
            if !taken.contains(candidate) { return candidate }
        }
        return JoinCode.generate()
    }
}


/// Stand-in for the environment's default value. Deliberately touches no
/// storage: building a ModelContainer here would open a second store at the
/// same default path and clobber the real one.
struct UnavailableTeamRepository: TeamRepository {
    var entitlements: Entitlements { .free }
    func ownedTeamCount(forUser userId: String) async throws -> Int { 0 }
    func teams(forUser userId: String) async throws -> [Team] { [] }
    func members(of teamId: UUID) async throws -> [TeamMember] { [] }
    func createTeam(name: String, userId: String, displayName: String) async throws -> Team {
        throw TeamError.notAuthorised
    }
    func joinTeam(code: String, userId: String, displayName: String) async throws -> Team {
        throw TeamError.notAuthorised
    }
    func rename(teamId: UUID, to name: String) async throws {}
    func regenerateJoinCode(teamId: UUID, by userId: String) async throws -> String {
        throw TeamError.notAuthorised
    }
    func removeMember(_ memberId: UUID, by userId: String) async throws {}
    func leaveTeam(teamId: UUID, userId: String) async throws {}
    func deleteTeam(teamId: UUID, by userId: String) async throws {}
}
