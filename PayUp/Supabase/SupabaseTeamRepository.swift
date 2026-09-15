import Foundation
import Supabase

/// Remote implementation. Sits alongside LocalTeamRepository rather than
/// replacing it — the local one remains the test double.
///
/// Team creation and joining go through Postgres functions, not table writes:
/// row-level security means a client cannot select a team it isn't already a
/// member of, so joining by code is impossible as a plain query.
struct SupabaseTeamRepository: TeamRepository {
    let client: SupabaseClient
    var entitlementsProvider: EntitlementsProvider = FreeEntitlementsProvider()

    var entitlements: Entitlements { entitlementsProvider.current }

    // MARK: - Wire models

    private struct TeamRow: Decodable {
        let id: UUID
        let name: String
        let joinCode: String
        let createdAt: Date
    }

    private struct MemberRow: Decodable {
        let id: UUID
        let teamId: UUID
        let userId: String
        let displayName: String
        let role: String
        let joinedAt: Date
    }

    // MARK: - Reads

    func teams(forUser userId: String) async throws -> [Team] {
        let rows: [MemberRow] = try await run {
            try await client.from("team_members")
                .select()
                .eq("user_id", value: userId)
                .execute()
                .value
        }
        guard !rows.isEmpty else { return [] }

        let teamRows: [TeamRow] = try await run {
            try await client.from("teams")
                .select()
                .in("id", values: rows.map(\.teamId.uuidString))
                .order("created_at", ascending: true)
                .execute()
                .value
        }
        return teamRows.map(team(from:))
    }

    func members(of teamId: UUID) async throws -> [TeamMember] {
        let rows: [MemberRow] = try await run {
            try await client.from("team_members")
                .select()
                .eq("team_id", value: teamId.uuidString)
                .order("joined_at", ascending: true)
                .execute()
                .value
        }
        return rows.map(member(from:))
    }

    func ownedTeamCount(forUser userId: String) async throws -> Int {
        let rows: [MemberRow] = try await run {
            try await client.from("team_members")
                .select()
                .eq("user_id", value: userId)
                .eq("role", value: TeamRole.owner.rawValue)
                .execute()
                .value
        }
        return rows.count
    }

    // MARK: - RPCs

    func createTeam(name: String, userId: String, displayName: String) async throws -> Team {
        // Client-side entitlement check is a fast path that saves a round trip.
        // The database trigger is the authority; if it disagrees, its error wins.
        let limit = entitlements.maxTeamsOwned
        if let count = try? await ownedTeamCount(forUser: userId), count >= limit {
            throw TeamError.teamLimitReached(limit: limit)
        }

        let row: TeamRow = try await run {
            try await client.rpc("create_team", params: [
                "team_name": name,
                "display_name": displayName
            ])
            .single()
            .execute()
            .value
        }
        return team(from: row)
    }

    func joinTeam(code: String, userId: String, displayName: String) async throws -> Team {
        let row: TeamRow = try await run {
            try await client.rpc("join_team", params: [
                "code": JoinCode.normalise(code),
                "display_name": displayName
            ])
            .single()
            .execute()
            .value
        }
        return team(from: row)
    }

    func regenerateJoinCode(teamId: UUID, by userId: String) async throws -> String {
        try await run {
            try await client.rpc("regenerate_join_code", params: [
                "target_team_id": teamId.uuidString
            ])
            .execute()
            .value
        }
    }

    // MARK: - Writes

    func rename(teamId: UUID, to name: String) async throws {
        try await run {
            _ = try await client.from("teams")
                .update(["name": name])
                .eq("id", value: teamId.uuidString)
                .execute()
        }
    }

    func removeMember(_ memberId: UUID, by userId: String) async throws {
        try await run {
            _ = try await client.from("team_members")
                .delete()
                .eq("id", value: memberId.uuidString)
                .execute()
        }
    }

    func leaveTeam(teamId: UUID, userId: String) async throws {
        try await run {
            _ = try await client.from("team_members")
                .delete()
                .eq("team_id", value: teamId.uuidString)
                .eq("user_id", value: userId)
                .execute()
        }
    }

    func deleteTeam(teamId: UUID, by userId: String) async throws {
        try await run {
            _ = try await client.from("teams")
                .delete()
                .eq("id", value: teamId.uuidString)
                .execute()
        }
    }

    // MARK: - Plumbing

    /// Every call funnels through here so server errors become TeamErrors in
    /// exactly one place.
    private func run<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as TeamError {
            throw error
        } catch {
            throw PostgresErrorMapper.teamError(
                from: message(from: error),
                fallbackLimit: entitlements.maxTeamsOwned
            )
        }
    }

    private func message(from error: Error) -> String {
        if let postgrest = error as? PostgrestError {
            return [postgrest.message, postgrest.hint, postgrest.details]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return error.localizedDescription
    }

    private func team(from row: TeamRow) -> Team {
        let team = Team(id: row.id, name: row.name, joinCode: row.joinCode)
        team.createdAt = row.createdAt
        return team
    }

    private func member(from row: MemberRow) -> TeamMember {
        let member = TeamMember(
            teamId: row.teamId,
            userId: row.userId,
            displayName: row.displayName,
            role: TeamRole(rawValue: row.role)
        )
        member.id = row.id
        member.joinedAt = row.joinedAt
        return member
    }
}
