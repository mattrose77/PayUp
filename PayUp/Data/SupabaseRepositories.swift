import Foundation
import Supabase

/// Shared plumbing: one place where server errors become TeamErrors, matching
/// what SupabaseTeamRepository already does.
struct RemoteCall {
    static func run<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as TeamError {
            throw error
        } catch {
            throw PostgresErrorMapper.teamError(from: message(from: error), fallbackLimit: 1)
        }
    }

    private static func message(from error: Error) -> String {
        if let postgrest = error as? PostgrestError {
            return [postgrest.code, postgrest.message, postgrest.hint, postgrest.details]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return error.localizedDescription
    }
}

struct SupabasePlayerRepository: PlayerRepository {
    let client: SupabaseClient

    private struct Insert: Encodable {
        let teamId: UUID
        let name: String
    }

    func players(teamId: UUID) async throws -> [Player] {
        try await RemoteCall.run {
            try await client.from("players")
                .select()
                .eq("team_id", value: teamId.uuidString)
                .order("name", ascending: true)
                .execute()
                .value
        }
    }

    func add(name: String, teamId: UUID) async throws -> Player {
        try await RemoteCall.run {
            try await client.from("players")
                .insert(Insert(teamId: teamId, name: name))
                .select()
                .single()
                .execute()
                .value
        }
    }

    func rename(_ id: UUID, to name: String) async throws -> Player {
        try await RemoteCall.run {
            try await client.from("players")
                .update(["name": name])
                .eq("id", value: id.uuidString)
                .select()
                .single()
                .execute()
                .value
        }
    }

    func setActive(_ id: UUID, active: Bool) async throws -> Player {
        try await RemoteCall.run {
            try await client.from("players")
                .update(["active": active])
                .eq("id", value: id.uuidString)
                .select()
                .single()
                .execute()
                .value
        }
    }

    func delete(_ id: UUID) async throws {
        try await RemoteCall.run {
            _ = try await client.from("players")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        }
    }
}

struct SupabaseFineTypeRepository: FineTypeRepository {
    let client: SupabaseClient

    private struct Insert: Encodable {
        let teamId: UUID
        let name: String
        let amountPence: Int
        let sortOrder: Int
    }

    private struct Update: Encodable {
        let name: String
        let amountPence: Int
    }

    func fineTypes(teamId: UUID) async throws -> [FineType] {
        try await RemoteCall.run {
            try await client.from("fine_types")
                .select()
                .eq("team_id", value: teamId.uuidString)
                .order("sort_order", ascending: true)
                .execute()
                .value
        }
    }

    func add(name: String, amountPence: Int, sortOrder: Int, teamId: UUID) async throws -> FineType {
        try await RemoteCall.run {
            try await client.from("fine_types")
                .insert(Insert(teamId: teamId, name: name, amountPence: amountPence, sortOrder: sortOrder))
                .select()
                .single()
                .execute()
                .value
        }
    }

    func update(_ id: UUID, name: String, amountPence: Int) async throws -> FineType {
        try await RemoteCall.run {
            try await client.from("fine_types")
                .update(Update(name: name, amountPence: amountPence))
                .eq("id", value: id.uuidString)
                .select()
                .single()
                .execute()
                .value
        }
    }

    func setActive(_ id: UUID, active: Bool) async throws -> FineType {
        try await RemoteCall.run {
            try await client.from("fine_types")
                .update(["active": active])
                .eq("id", value: id.uuidString)
                .select()
                .single()
                .execute()
                .value
        }
    }

    func delete(_ id: UUID) async throws {
        try await RemoteCall.run {
            _ = try await client.from("fine_types")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        }
    }
}

struct SupabaseMatchRepository: MatchRepository {
    let client: SupabaseClient

    private struct Insert: Encodable {
        let teamId: UUID
        let opponent: String
        /// `played_on` is a bare date, so it goes over as yyyy-MM-dd.
        let playedOn: String
        let itemOfTheWeek: String
    }

    private struct CompleteUpdate: Encodable {
        let isComplete: Bool
        let completedAt: String?

        enum CodingKeys: String, CodingKey { case isComplete, completedAt }

        /// Synthesised Encodable drops nil optionals, so reopening would leave
        /// the old `completed_at` in place. Send an explicit null instead.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(isComplete, forKey: .isComplete)
            try container.encode(completedAt, forKey: .completedAt)
        }
    }

    func matches(teamId: UUID) async throws -> [Match] {
        try await RemoteCall.run {
            try await client.from("matches")
                .select()
                .eq("team_id", value: teamId.uuidString)
                .order("played_on", ascending: false)
                .execute()
                .value
        }
    }

    func add(opponent: String, playedOn: Date, itemOfTheWeek: String, teamId: UUID) async throws -> Match {
        try await RemoteCall.run {
            try await client.from("matches")
                .insert(Insert(
                    teamId: teamId,
                    opponent: opponent,
                    playedOn: PostgresDate.day(from: playedOn),
                    itemOfTheWeek: itemOfTheWeek
                ))
                .select()
                .single()
                .execute()
                .value
        }
    }

    func setComplete(_ id: UUID, complete: Bool) async throws -> Match {
        try await RemoteCall.run {
            try await client.from("matches")
                .update(CompleteUpdate(
                    isComplete: complete,
                    completedAt: complete ? ISO8601DateFormatter().string(from: Date()) : nil
                ))
                .eq("id", value: id.uuidString)
                .select()
                .single()
                .execute()
                .value
        }
    }

    func delete(_ id: UUID) async throws {
        try await RemoteCall.run {
            _ = try await client.from("matches")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        }
    }
}

struct SupabaseFineRepository: FineRepository {
    let client: SupabaseClient

    private struct Insert: Encodable {
        let teamId: UUID
        let matchId: UUID
        let playerId: UUID
        let fineTypeId: UUID?
        let description: String
        let amountPence: Int
        let createdBy: UUID?
    }

    private struct PaidUpdate: Encodable {
        let paid: Bool
        let paidAt: String?

        enum CodingKeys: String, CodingKey { case paid, paidAt }

        /// Explicit null so marking a fine unpaid clears `paid_at` — the
        /// synthesised version would omit the key and leave the old timestamp.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(paid, forKey: .paid)
            try container.encode(paidAt, forKey: .paidAt)
        }
    }

    func fines(teamId: UUID) async throws -> [Fine] {
        try await RemoteCall.run {
            try await client.from("fines")
                .select()
                .eq("team_id", value: teamId.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
        }
    }

    func add(_ draft: FineDraft) async throws -> Fine {
        try await RemoteCall.run {
            try await client.from("fines")
                .insert(Insert(
                    teamId: draft.teamId,
                    matchId: draft.matchId,
                    playerId: draft.playerId,
                    fineTypeId: draft.fineTypeId,
                    description: draft.description,
                    amountPence: draft.amountPence,
                    createdBy: draft.createdBy.flatMap(UUID.init(uuidString:))
                ))
                .select()
                .single()
                .execute()
                .value
        }
    }

    func setPaid(_ id: UUID, paid: Bool) async throws -> Fine {
        try await RemoteCall.run {
            try await client.from("fines")
                .update(PaidUpdate(
                    paid: paid,
                    paidAt: paid ? ISO8601DateFormatter().string(from: Date()) : nil
                ))
                .eq("id", value: id.uuidString)
                .select()
                .single()
                .execute()
                .value
        }
    }

    func settle(ids: [UUID]) async throws -> [Fine] {
        guard !ids.isEmpty else { return [] }
        return try await RemoteCall.run {
            try await client.from("fines")
                .update(PaidUpdate(paid: true, paidAt: ISO8601DateFormatter().string(from: Date())))
                .in("id", values: ids.map(\.uuidString))
                .select()
                .execute()
                .value
        }
    }

    func delete(_ id: UUID) async throws {
        try await RemoteCall.run {
            _ = try await client.from("fines")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        }
    }
}
