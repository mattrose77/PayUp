import XCTest
@testable import PayUp

/// Rules the server enforces, mirrored in the local doubles so they can be
/// checked without a network.
final class DataRepositoryTests: XCTestCase {
    private var store: LocalStore!
    private var players: LocalPlayerRepository!
    private var types: LocalFineTypeRepository!
    private var matches: LocalMatchRepository!
    private var fines: LocalFineRepository!

    private let teamA = UUID()
    private let teamB = UUID()

    override func setUp() {
        store = LocalStore()
        players = LocalPlayerRepository(store: store)
        types = LocalFineTypeRepository(store: store)
        matches = LocalMatchRepository(store: store)
        fines = LocalFineRepository(store: store)
    }

    @discardableResult
    private func fine(
        team: UUID, match: Match, player: Player, type: FineType?
    ) async throws -> Fine {
        try await fines.add(FineDraft(
            teamId: team, matchId: match.id, playerId: player.id,
            fineTypeId: type?.id,
            description: type?.name ?? "Manual",
            amountPence: type?.amountPence ?? 100,
            createdBy: nil
        ))
    }

    // MARK: - Team scoping

    func testPlayersNeverLeakAcrossTeams() async throws {
        _ = try await players.add(name: "Ours", teamId: teamA)
        _ = try await players.add(name: "Theirs", teamId: teamB)

        let mine = try await players.players(teamId: teamA)
        XCTAssertEqual(mine.map(\.name), ["Ours"])
        XCTAssertTrue(mine.allSatisfy { $0.teamId == teamA })
    }

    func testFineTypesMatchesAndFinesNeverLeakAcrossTeams() async throws {
        let ourPlayer = try await players.add(name: "Ours", teamId: teamA)
        let theirPlayer = try await players.add(name: "Theirs", teamId: teamB)
        let ourType = try await types.add(name: "Late", amountPence: 200, sortOrder: 0, teamId: teamA)
        let theirType = try await types.add(name: "Late", amountPence: 500, sortOrder: 0, teamId: teamB)
        let ourMatch = try await matches.add(opponent: "Grove", playedOn: .now, itemOfTheWeek: "", teamId: teamA)
        let theirMatch = try await matches.add(opponent: "Other", playedOn: .now, itemOfTheWeek: "", teamId: teamB)
        try await fine(team: teamA, match: ourMatch, player: ourPlayer, type: ourType)
        try await fine(team: teamB, match: theirMatch, player: theirPlayer, type: theirType)

        let scopedTypes = try await types.fineTypes(teamId: teamA)
        let scopedMatches = try await matches.matches(teamId: teamA)
        let scopedFines = try await fines.fines(teamId: teamA)

        XCTAssertEqual(scopedTypes.count, 1)
        XCTAssertEqual(scopedMatches.map(\.opponent), ["Grove"])
        XCTAssertEqual(scopedFines.count, 1)
        XCTAssertTrue(scopedFines.allSatisfy { $0.teamId == teamA })
    }

    // MARK: - Player deletion

    func testDeletingAPlayerWithFinesIsRejected() async throws {
        let player = try await players.add(name: "Jamie", teamId: teamA)
        let type = try await types.add(name: "Late", amountPence: 200, sortOrder: 0, teamId: teamA)
        let match = try await matches.add(opponent: "Grove", playedOn: .now, itemOfTheWeek: "", teamId: teamA)
        try await fine(team: teamA, match: match, player: player, type: type)

        await XCTAssertThrowsErrorAsync(try await players.delete(player.id)) {
            XCTAssertEqual($0 as? TeamError, .playerHasFines)
        }

        let remaining = try await players.players(teamId: teamA)
        XCTAssertEqual(remaining.count, 1, "the player is still there")
    }

    func testDeletingAPlayerWithNoFinesSucceeds() async throws {
        let player = try await players.add(name: "Newcomer", teamId: teamA)
        try await players.delete(player.id)
        let remaining = try await players.players(teamId: teamA)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeactivatingKeepsFinesAndBalanceIntact() async throws {
        let player = try await players.add(name: "Jamie", teamId: teamA)
        let type = try await types.add(name: "Late", amountPence: 200, sortOrder: 0, teamId: teamA)
        let match = try await matches.add(opponent: "Grove", playedOn: .now, itemOfTheWeek: "", teamId: teamA)
        try await fine(team: teamA, match: match, player: player, type: type)

        let updated = try await players.setActive(player.id, active: false)
        XCTAssertFalse(updated.active)

        let theirFines = try await fines.fines(teamId: teamA).filter { $0.playerId == player.id }
        XCTAssertEqual(theirFines.count, 1)
        XCTAssertEqual(theirFines.outstandingPence, 200, "they still owe it")

        let roster = try await players.players(teamId: teamA)
        XCTAssertEqual(roster.filter(\.active).count, 0, "kept off the matchday list")
        XCTAssertEqual(roster.count, 1, "but not gone")
    }

    // MARK: - Fine type deletion

    func testDeletingAFineTypeLeavesItsFinesReadable() async throws {
        let player = try await players.add(name: "Jamie", teamId: teamA)
        let type = try await types.add(name: "Dick of the day", amountPence: 300, sortOrder: 0, teamId: teamA)
        let match = try await matches.add(opponent: "Grove", playedOn: .now, itemOfTheWeek: "", teamId: teamA)
        try await fine(team: teamA, match: match, player: player, type: type)

        try await types.delete(type.id)

        let remaining = try await fines.fines(teamId: teamA)
        XCTAssertEqual(remaining.count, 1, "the fine survives its type")
        let orphan = try XCTUnwrap(remaining.first)
        XCTAssertNil(orphan.fineTypeId, "the link is nulled")
        XCTAssertEqual(orphan.description, "Dick of the day", "its own description still reads")
        XCTAssertEqual(orphan.amountPence, 300, "and it still knows what it cost")
    }

    // MARK: - Match deletion

    func testDeletingAMatchCascadesItsFines() async throws {
        let player = try await players.add(name: "Jamie", teamId: teamA)
        let type = try await types.add(name: "Late", amountPence: 200, sortOrder: 0, teamId: teamA)
        let doomed = try await matches.add(opponent: "Grove", playedOn: .now, itemOfTheWeek: "", teamId: teamA)
        let survivor = try await matches.add(opponent: "Upton", playedOn: .now, itemOfTheWeek: "", teamId: teamA)
        try await fine(team: teamA, match: doomed, player: player, type: type)
        try await fine(team: teamA, match: doomed, player: player, type: type)
        try await fine(team: teamA, match: survivor, player: player, type: type)

        try await matches.delete(doomed.id)

        let remaining = try await fines.fines(teamId: teamA)
        XCTAssertEqual(remaining.count, 1, "both of the deleted match's fines went with it")
        XCTAssertEqual(remaining.first?.matchId, survivor.id)

        let players = try await self.players.players(teamId: teamA)
        XCTAssertEqual(players.count, 1, "the player is untouched")
    }

    // MARK: - Matchday lock

    func testCompletingAndReopeningAMatch() async throws {
        let match = try await matches.add(opponent: "Grove", playedOn: .now, itemOfTheWeek: "Cone", teamId: teamA)
        XCTAssertFalse(match.isComplete)

        let locked = try await matches.setComplete(match.id, complete: true)
        XCTAssertTrue(locked.isComplete)
        XCTAssertNotNil(locked.completedAt)

        let reopened = try await matches.setComplete(match.id, complete: false)
        XCTAssertFalse(reopened.isComplete)
        XCTAssertNil(reopened.completedAt)
    }

    // MARK: - Settling

    func testSettlingMarksOnlyTheGivenFinesPaid() async throws {
        let player = try await players.add(name: "Jamie", teamId: teamA)
        let type = try await types.add(name: "Late", amountPence: 200, sortOrder: 0, teamId: teamA)
        let match = try await matches.add(opponent: "Grove", playedOn: .now, itemOfTheWeek: "", teamId: teamA)
        let first = try await fine(team: teamA, match: match, player: player, type: type)
        _ = try await fine(team: teamA, match: match, player: player, type: type)

        _ = try await fines.settle(ids: [first.id])

        let all = try await fines.fines(teamId: teamA)
        XCTAssertEqual(all.paidPence, 200)
        XCTAssertEqual(all.outstandingPence, 200)
    }
}

/// A new team gets nothing — the empty states carry the onboarding instead.
final class NoSeedingTests: XCTestCase {
    func testANewTeamStartsWithNoFineTypesOrPlayers() async throws {
        let store = LocalStore()
        let teamId = UUID()
        let types = try await LocalFineTypeRepository(store: store).fineTypes(teamId: teamId)
        let roster = try await LocalPlayerRepository(store: store).players(teamId: teamId)

        XCTAssertTrue(types.isEmpty, "no default fines list is seeded")
        XCTAssertTrue(roster.isEmpty)
    }
}
