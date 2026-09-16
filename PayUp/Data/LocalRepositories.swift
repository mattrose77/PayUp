import Foundation

/// In-memory doubles. Kept alongside the Supabase versions so the rules can be
/// tested without a network, exactly as LocalTeamRepository does for teams.
///
/// These mirror the server's constraints deliberately: the team scoping, the
/// restrict-on-delete for players with fines, the null-out of fine_type_id and
/// the cascade from matches to fines. If a rule changes server-side it has to
/// change here too, or the tests stop meaning anything.
actor LocalStore {
    var players: [Player] = []
    var fineTypes: [FineType] = []
    var matches: [Match] = []
    var fines: [Fine] = []

    func reset() {
        players = []; fineTypes = []; matches = []; fines = []
    }

    func insert(_ player: Player) { players.append(player) }
    func insert(_ type: FineType) { fineTypes.append(type) }
    func insert(_ match: Match) { matches.append(match) }
    func insert(_ fine: Fine) { fines.append(fine) }

    func mutatePlayer(_ id: UUID, _ change: (inout Player) -> Void) -> Player? {
        guard let index = players.firstIndex(where: { $0.id == id }) else { return nil }
        change(&players[index])
        return players[index]
    }

    func mutateFineType(_ id: UUID, _ change: (inout FineType) -> Void) -> FineType? {
        guard let index = fineTypes.firstIndex(where: { $0.id == id }) else { return nil }
        change(&fineTypes[index])
        return fineTypes[index]
    }

    func mutateMatch(_ id: UUID, _ change: (inout Match) -> Void) -> Match? {
        guard let index = matches.firstIndex(where: { $0.id == id }) else { return nil }
        change(&matches[index])
        return matches[index]
    }

    func mutateFine(_ id: UUID, _ change: (inout Fine) -> Void) -> Fine? {
        guard let index = fines.firstIndex(where: { $0.id == id }) else { return nil }
        change(&fines[index])
        return fines[index]
    }

    func removePlayer(_ id: UUID) { players.removeAll { $0.id == id } }
    func removeFineType(_ id: UUID) {
        fineTypes.removeAll { $0.id == id }
        // Mirrors `on delete set null`: the fine keeps its own description and
        // amount, so history stays readable.
        for index in fines.indices where fines[index].fineTypeId == id {
            fines[index].fineTypeId = nil
        }
    }
    func removeMatch(_ id: UUID) {
        matches.removeAll { $0.id == id }
        fines.removeAll { $0.matchId == id }   // mirrors `on delete cascade`
    }
    func removeFine(_ id: UUID) { fines.removeAll { $0.id == id } }

    func finesFor(player id: UUID) -> [Fine] { fines.filter { $0.playerId == id } }

    /// Mirrors what `delete_account()` does when the last owner leaves. Fines
    /// go first on purpose: `fines.player_id` is `on delete restrict`, so
    /// cascading the team straight to players would be blocked by them.
    func removeTeam(_ teamId: UUID) {
        fines.removeAll { $0.teamId == teamId }
        matches.removeAll { $0.teamId == teamId }
        players.removeAll { $0.teamId == teamId }
        fineTypes.removeAll { $0.teamId == teamId }
    }

    func counts(teamId: UUID) -> TeamContents {
        TeamContents(
            players: players.filter { $0.teamId == teamId }.count,
            matches: matches.filter { $0.teamId == teamId }.count,
            fines: fines.filter { $0.teamId == teamId }.count
        )
    }
}

struct LocalPlayerRepository: PlayerRepository {
    let store: LocalStore

    func players(teamId: UUID) async throws -> [Player] {
        await store.players.filter { $0.teamId == teamId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func add(name: String, teamId: UUID) async throws -> Player {
        let player = Player(
            id: UUID(), teamId: teamId, name: name,
            active: true, userId: nil, createdAt: Date()
        )
        await store.insert(player)
        return player
    }

    func rename(_ id: UUID, to name: String) async throws -> Player {
        guard let updated = await store.mutatePlayer(id, { $0.name = name }) else {
            throw TeamError.serverRejected("player not found")
        }
        return updated
    }

    func setActive(_ id: UUID, active: Bool) async throws -> Player {
        guard let updated = await store.mutatePlayer(id, { $0.active = active }) else {
            throw TeamError.serverRejected("player not found")
        }
        return updated
    }

    func delete(_ id: UUID) async throws {
        // `on delete restrict`: a player with history can't be removed.
        guard await store.finesFor(player: id).isEmpty else {
            throw TeamError.playerHasFines
        }
        await store.removePlayer(id)
    }
}

struct LocalFineTypeRepository: FineTypeRepository {
    let store: LocalStore

    func fineTypes(teamId: UUID) async throws -> [FineType] {
        await store.fineTypes.filter { $0.teamId == teamId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func add(name: String, amountPence: Int, sortOrder: Int, teamId: UUID) async throws -> FineType {
        let type = FineType(
            id: UUID(), teamId: teamId, name: name, amountPence: amountPence,
            active: true, sortOrder: sortOrder, createdAt: Date()
        )
        await store.insert(type)
        return type
    }

    func update(_ id: UUID, name: String, amountPence: Int) async throws -> FineType {
        guard let updated = await store.mutateFineType(id, {
            $0.name = name
            $0.amountPence = amountPence
        }) else { throw TeamError.serverRejected("fine type not found") }
        return updated
    }

    func setActive(_ id: UUID, active: Bool) async throws -> FineType {
        guard let updated = await store.mutateFineType(id, { $0.active = active }) else {
            throw TeamError.serverRejected("fine type not found")
        }
        return updated
    }

    func delete(_ id: UUID) async throws {
        await store.removeFineType(id)
    }
}

struct LocalMatchRepository: MatchRepository {
    let store: LocalStore

    func matches(teamId: UUID) async throws -> [Match] {
        await store.matches.filter { $0.teamId == teamId }
            .sorted { $0.playedOn > $1.playedOn }
    }

    func add(opponent: String, playedOn: Date, itemOfTheWeek: String, teamId: UUID) async throws -> Match {
        let match = Match(
            id: UUID(), teamId: teamId, opponent: opponent, playedOn: playedOn,
            isComplete: false, completedAt: nil, itemOfTheWeek: itemOfTheWeek,
            createdAt: Date()
        )
        await store.insert(match)
        return match
    }

    func setComplete(_ id: UUID, complete: Bool) async throws -> Match {
        guard let updated = await store.mutateMatch(id, {
            $0.isComplete = complete
            $0.completedAt = complete ? Date() : nil
        }) else { throw TeamError.serverRejected("match not found") }
        return updated
    }

    func delete(_ id: UUID) async throws {
        await store.removeMatch(id)
    }
}

struct LocalFineRepository: FineRepository {
    let store: LocalStore

    func fines(teamId: UUID) async throws -> [Fine] {
        await store.fines.filter { $0.teamId == teamId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func add(_ draft: FineDraft) async throws -> Fine {
        let fine = Fine(
            id: UUID(), teamId: draft.teamId, matchId: draft.matchId,
            playerId: draft.playerId, fineTypeId: draft.fineTypeId,
            description: draft.description, amountPence: draft.amountPence,
            paid: false, paidAt: nil, createdBy: draft.createdBy, createdAt: Date()
        )
        await store.insert(fine)
        return fine
    }

    func setPaid(_ id: UUID, paid: Bool) async throws -> Fine {
        guard let updated = await store.mutateFine(id, {
            $0.paid = paid
            $0.paidAt = paid ? Date() : nil
        }) else { throw TeamError.serverRejected("fine not found") }
        return updated
    }

    func settle(ids: [UUID]) async throws -> [Fine] {
        var updated: [Fine] = []
        for id in ids {
            if let fine = await store.mutateFine(id, { $0.paid = true; $0.paidAt = Date() }) {
                updated.append(fine)
            }
        }
        return updated
    }

    func delete(_ id: UUID) async throws {
        await store.removeFine(id)
    }
}
