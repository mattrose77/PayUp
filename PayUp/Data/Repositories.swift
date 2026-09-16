import Foundation

/// One protocol per table, each with a local double and a Supabase
/// implementation — the same split the team layer already uses.
///
/// Every read takes a teamId. Nothing fetches unscoped and filters afterwards:
/// that would both leak another team's rows into memory and lean on the client
/// for something row-level security should be doing.

protocol PlayerRepository {
    func players(teamId: UUID) async throws -> [Player]
    func add(name: String, teamId: UUID) async throws -> Player
    func rename(_ id: UUID, to name: String) async throws -> Player
    func setActive(_ id: UUID, active: Bool) async throws -> Player
    func delete(_ id: UUID) async throws
}

protocol FineTypeRepository {
    func fineTypes(teamId: UUID) async throws -> [FineType]
    func add(name: String, amountPence: Int, sortOrder: Int, teamId: UUID) async throws -> FineType
    func update(_ id: UUID, name: String, amountPence: Int) async throws -> FineType
    func setActive(_ id: UUID, active: Bool) async throws -> FineType
    func delete(_ id: UUID) async throws
}

protocol MatchRepository {
    func matches(teamId: UUID) async throws -> [Match]
    func add(opponent: String, playedOn: Date, itemOfTheWeek: String, teamId: UUID) async throws -> Match
    func setComplete(_ id: UUID, complete: Bool) async throws -> Match
    func delete(_ id: UUID) async throws
}

struct FineDraft {
    var teamId: UUID
    var matchId: UUID
    var playerId: UUID
    var fineTypeId: UUID?
    var description: String
    var amountPence: Int
    var createdBy: String?
}

protocol FineRepository {
    func fines(teamId: UUID) async throws -> [Fine]
    func add(_ draft: FineDraft) async throws -> Fine
    func setPaid(_ id: UUID, paid: Bool) async throws -> Fine
    func settle(ids: [UUID]) async throws -> [Fine]
    func delete(_ id: UUID) async throws
}
