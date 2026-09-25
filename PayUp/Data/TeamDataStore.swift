import Foundation
import Observation

/// Holds the team's data for the whole app. One fetch, one loading state, one
/// error state — rather than six screens each inventing their own.
///
/// Writes go to the server first and the local arrays are updated from the
/// response. Nothing is applied optimistically: a write that fails leaves the
/// UI exactly as it was rather than showing a change that quietly reverts.
@MainActor
@Observable
final class TeamDataStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// Distinct from "loaded but empty" on purpose — an empty list because
        /// the fetch failed must never look like an empty list because there's
        /// no data.
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var players: [Player] = []
    private(set) var fineTypes: [FineType] = []
    private(set) var matches: [Match] = []
    private(set) var fines: [Fine] = []

    /// Readable so the session can tell whether the store it holds still
    /// belongs to the current team.
    let teamId: UUID
    private let userId: String
    private let playerRepo: PlayerRepository
    private let fineTypeRepo: FineTypeRepository
    private let matchRepo: MatchRepository
    private let fineRepo: FineRepository

    init(
        teamId: UUID,
        userId: String,
        players: PlayerRepository,
        fineTypes: FineTypeRepository,
        matches: MatchRepository,
        fines: FineRepository
    ) {
        self.teamId = teamId
        self.userId = userId
        self.playerRepo = players
        self.fineTypeRepo = fineTypes
        self.matchRepo = matches
        self.fineRepo = fines
    }

    // MARK: - Reading

    var activePlayers: [Player] { players.filter(\.active) }
    var activeFineTypes: [FineType] { fineTypes.filter(\.active) }
    var seasonStats: SeasonStats { SeasonStats(fines: fines) }

    func fines(forMatch id: UUID) -> [Fine] { fines.filter { $0.matchId == id } }
    func fines(forPlayer id: UUID) -> [Fine] { fines.filter { $0.playerId == id } }
    func player(_ id: UUID) -> Player? { players.first { $0.id == id } }
    func match(_ id: UUID) -> Match? { matches.first { $0.id == id } }

    func fines(forMatch matchId: UUID, player playerId: UUID) -> [Fine] {
        fines.filter { $0.matchId == matchId && $0.playerId == playerId }
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await load()
    }

    func load() async {
        let hadData = state == .loaded
        if !hadData { state = .loading }
        do {
            async let players = playerRepo.players(teamId: teamId)
            async let types = fineTypeRepo.fineTypes(teamId: teamId)
            async let matches = matchRepo.matches(teamId: teamId)
            async let fines = fineRepo.fines(teamId: teamId)

            // All four land before any is applied, so a failure part-way can't
            // leave fines pointing at a player list from a different moment.
            let fetched = try await (players, types, matches, fines)
            self.players = fetched.0
            self.fineTypes = fetched.1
            self.matches = fetched.2
            self.fines = fetched.3
            refreshError = nil
            state = .loaded
        } catch {
            if hadData {
                // Keep showing what's there; say the refresh didn't work.
                refreshError = error.localizedDescription
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// A failed pull-to-refresh over data that's already on screen. Shown as a
    /// banner rather than replacing the screen with an error.
    private(set) var refreshError: String?

    /// Pull-to-refresh: keep showing what's there, replace it if the fetch works.
    func refresh() async {
        await load()
    }

    // MARK: - Players

    func addPlayer(name: String) async throws {
        let player = try await playerRepo.add(name: name, teamId: teamId)
        players.append(player)
        players.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setPlayerActive(_ player: Player, active: Bool) async throws {
        let updated = try await playerRepo.setActive(player.id, active: active)
        replace(updated)
    }

    /// Only ever offered for a player with no fines; the server enforces it too.
    func deletePlayer(_ player: Player) async throws {
        try await playerRepo.delete(player.id)
        players.removeAll { $0.id == player.id }
    }

    // MARK: - Fine types

    func addFineType(name: String, amountPence: Int) async throws {
        let next = (fineTypes.map(\.sortOrder).max() ?? -1) + 1
        let type = try await fineTypeRepo.add(
            name: name, amountPence: amountPence, sortOrder: next, teamId: teamId
        )
        fineTypes.append(type)
    }

    func updateFineType(_ type: FineType, name: String, amountPence: Int) async throws {
        let updated = try await fineTypeRepo.update(type.id, name: name, amountPence: amountPence)
        replace(updated)
    }

    func setFineTypeActive(_ type: FineType, active: Bool) async throws {
        let updated = try await fineTypeRepo.setActive(type.id, active: active)
        replace(updated)
    }

    /// Existing fines keep their own description and amount; only the link goes.
    func deleteFineType(_ type: FineType) async throws {
        try await fineTypeRepo.delete(type.id)
        fineTypes.removeAll { $0.id == type.id }
        for index in fines.indices where fines[index].fineTypeId == type.id {
            fines[index].fineTypeId = nil
        }
    }

    // MARK: - Matches

    func addMatch(opponent: String, playedOn: Date, itemOfTheWeek: String) async throws -> Match {
        let match = try await matchRepo.add(
            opponent: opponent, playedOn: playedOn,
            itemOfTheWeek: itemOfTheWeek, teamId: teamId
        )
        matches.append(match)
        matches.sort { $0.playedOn > $1.playedOn }
        return match
    }

    func setMatchComplete(_ match: Match, complete: Bool) async throws {
        let updated = try await matchRepo.setComplete(match.id, complete: complete)
        replace(updated)
    }

    func deleteMatch(_ match: Match) async throws {
        try await matchRepo.delete(match.id)
        matches.removeAll { $0.id == match.id }
        fines.removeAll { $0.matchId == match.id }   // server cascades too
    }

    // MARK: - Fines

    func addFine(player: Player, type: FineType, match: Match) async throws -> Fine {
        let fine = try await fineRepo.add(FineDraft(
            teamId: teamId,
            matchId: match.id,
            playerId: player.id,
            fineTypeId: type.id,
            description: type.name,
            amountPence: type.amountPence,
            createdBy: userId
        ))
        fines.append(fine)
        return fine
    }

    func setFinePaid(_ fine: Fine, paid: Bool) async throws {
        let updated = try await fineRepo.setPaid(fine.id, paid: paid)
        replace(updated)
    }

    func settle(_ toSettle: [Fine]) async throws {
        let updated = try await fineRepo.settle(ids: toSettle.map(\.id))
        for fine in updated { replace(fine) }
    }

    func deleteFine(_ fine: Fine) async throws {
        try await fineRepo.delete(fine.id)
        fines.removeAll { $0.id == fine.id }
    }

    // MARK: - Helpers

    private func replace(_ player: Player) {
        if let index = players.firstIndex(where: { $0.id == player.id }) { players[index] = player }
    }
    private func replace(_ type: FineType) {
        if let index = fineTypes.firstIndex(where: { $0.id == type.id }) { fineTypes[index] = type }
    }
    private func replace(_ match: Match) {
        if let index = matches.firstIndex(where: { $0.id == match.id }) { matches[index] = match }
    }
    private func replace(_ fine: Fine) {
        if let index = fines.firstIndex(where: { $0.id == fine.id }) { fines[index] = fine }
    }
}
