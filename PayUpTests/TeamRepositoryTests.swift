import XCTest
import SwiftData
@testable import PayUp

/// Exercises the membership rules directly. These paths can't be reached from
/// the UI on one device — a second member needs a second store — so this is the
/// only place the cap, permissions and code invalidation are actually proven.
@MainActor
final class TeamRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repo: LocalTeamRepository!

    private let owner = "user-owner"
    private let mate = "user-mate"
    private let stranger = "user-stranger"

    override func setUpWithError() throws {
        let schema = Schema([Team.self, TeamMember.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repo = LocalTeamRepository(context: ModelContext(container))
    }

    override func tearDown() {
        container = nil
        repo = nil
    }

    @discardableResult
    private func makeTeam() async throws -> Team {
        try await repo.createTeam(name: "Minety FC", userId: owner, displayName: "Matt")
    }

    // MARK: - Creating

    func testCreatorBecomesOwner() async throws {
        let team = try await makeTeam()
        let members = try await repo.members(of: team.id)

        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.role, .owner)
        XCTAssertEqual(members.first?.userId, owner)
    }

    func testJoinCodeUsesUnambiguousAlphabet() async throws {
        for _ in 0..<200 {
            let code = JoinCode.generate()
            XCTAssertEqual(code.count, 6)
            for character in code {
                XCTAssertTrue(
                    JoinCode.alphabet.contains(character),
                    "\(character) should not appear in a join code"
                )
            }
            XCTAssertNil(code.rangeOfCharacter(from: CharacterSet(charactersIn: "O0I1")))
        }
    }

    func testTeamsForUserIsEmptyForNonMembers() async throws {
        try await makeTeam()
        let hoisted1 = try await repo.teams(forUser: stranger).isEmpty
        XCTAssertTrue(hoisted1)
        let hoisted2 = try await repo.teams(forUser: owner).count
        XCTAssertEqual(hoisted2, 1)
    }

    // MARK: - Joining

    func testSecondMemberJoinsAsAdmin() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")

        let members = try await repo.members(of: team.id)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members.last?.role, .admin)
    }

    func testJoinIsForgivingAboutFormatting() async throws {
        let team = try await makeTeam()
        let messy = " " + team.joinCode.lowercased() + "-"
        _ = try await repo.joinTeam(code: messy, userId: mate, displayName: "Sam")

        let hoisted3 = try await repo.members(of: team.id).count
        XCTAssertEqual(hoisted3, 2)
    }

    func testThirdMemberIsRejected() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")

        await XCTAssertThrowsErrorAsync(
            try await repo.joinTeam(code: team.joinCode, userId: stranger, displayName: "Nope")
        ) { XCTAssertEqual($0 as? TeamError, .teamFull) }

        let hoisted4 = try await repo.members(of: team.id).count
        XCTAssertEqual(hoisted4, TeamRules.maxMembers)
    }

    func testUnknownCodeIsRejected() async throws {
        try await makeTeam()
        await XCTAssertThrowsErrorAsync(
            try await repo.joinTeam(code: "ZZZZZZ", userId: mate, displayName: "Sam")
        ) { XCTAssertEqual($0 as? TeamError, .codeNotFound) }
    }

    func testJoiningTwiceIsRejected() async throws {
        let team = try await makeTeam()
        await XCTAssertThrowsErrorAsync(
            try await repo.joinTeam(code: team.joinCode, userId: owner, displayName: "Matt")
        ) { XCTAssertEqual($0 as? TeamError, .alreadyMember) }
    }

    // MARK: - Removing and leaving

    func testOwnerCanRemoveAdmin() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")
        let adminRoster = try await repo.members(of: team.id)
        let admin = try XCTUnwrap(adminRoster.first { $0.role == .admin })

        try await repo.removeMember(admin.id, by: owner)

        let remaining = try await repo.members(of: team.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.role, .owner)
    }

    func testAdminCannotRemoveOwner() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")
        let ownerMemberRoster = try await repo.members(of: team.id)
        let ownerMember = try XCTUnwrap(ownerMemberRoster.first { $0.role == .owner })

        await XCTAssertThrowsErrorAsync(try await repo.removeMember(ownerMember.id, by: mate)) {
            XCTAssertEqual($0 as? TeamError, .notAuthorised)
        }
        let hoisted5 = try await repo.members(of: team.id).count
        XCTAssertEqual(hoisted5, 2)
    }

    func testAdminCannotRemoveThemselves() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")
        let adminRoster = try await repo.members(of: team.id)
        let admin = try XCTUnwrap(adminRoster.first { $0.role == .admin })

        await XCTAssertThrowsErrorAsync(try await repo.removeMember(admin.id, by: mate)) {
            XCTAssertEqual($0 as? TeamError, .notAuthorised)
        }
    }

    func testAdminCanLeave() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")

        try await repo.leaveTeam(teamId: team.id, userId: mate)

        let hoisted6 = try await repo.members(of: team.id).count
        XCTAssertEqual(hoisted6, 1)
        let hoisted7 = try await repo.teams(forUser: mate).isEmpty
        XCTAssertTrue(hoisted7)
    }

    func testOwnerCannotLeave() async throws {
        let team = try await makeTeam()
        await XCTAssertThrowsErrorAsync(try await repo.leaveTeam(teamId: team.id, userId: owner)) {
            XCTAssertEqual($0 as? TeamError, .ownerCannotLeave)
        }
    }

    func testRemovingAMemberLeavesTeamDataUntouched() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")

        // The team's data lives in its own repositories now, not the team store.
        let data = LocalStore()
        let players = LocalPlayerRepository(store: data)
        let types = LocalFineTypeRepository(store: data)
        let matches = LocalMatchRepository(store: data)
        let fines = LocalFineRepository(store: data)

        let player = try await players.add(name: "Jamie Vasey", teamId: team.id)
        let type = try await types.add(name: "Late arrival", amountPence: 200, sortOrder: 0, teamId: team.id)
        let match = try await matches.add(
            opponent: "Grove", playedOn: .now, itemOfTheWeek: "", teamId: team.id
        )
        _ = try await fines.add(FineDraft(
            teamId: team.id, matchId: match.id, playerId: player.id,
            fineTypeId: type.id, description: type.name,
            amountPence: type.amountPence, createdBy: owner
        ))

        let adminRoster = try await repo.members(of: team.id)
        let admin = try XCTUnwrap(adminRoster.first { $0.role == .admin })
        try await repo.removeMember(admin.id, by: owner)

        let remainingPlayers = try await players.players(teamId: team.id)
        let remainingTypes = try await types.fineTypes(teamId: team.id)
        let remainingMatches = try await matches.matches(teamId: team.id)
        let remainingFines = try await fines.fines(teamId: team.id)
        XCTAssertEqual(remainingPlayers.count, 1)
        XCTAssertEqual(remainingTypes.count, 1)
        XCTAssertEqual(remainingMatches.count, 1)
        XCTAssertEqual(remainingFines.count, 1)
    }

    // MARK: - Join code lifecycle

    func testRegeneratingInvalidatesTheOldCode() async throws {
        let team = try await makeTeam()
        let original = team.joinCode

        let fresh = try await repo.regenerateJoinCode(teamId: team.id, by: owner)
        XCTAssertNotEqual(fresh, original)

        await XCTAssertThrowsErrorAsync(
            try await repo.joinTeam(code: original, userId: mate, displayName: "Sam")
        ) { XCTAssertEqual($0 as? TeamError, .codeNotFound) }

        _ = try await repo.joinTeam(code: fresh, userId: mate, displayName: "Sam")
        let hoisted8 = try await repo.members(of: team.id).count
        XCTAssertEqual(hoisted8, 2)
    }

    func testOnlyOwnerCanRegenerate() async throws {
        let team = try await makeTeam()
        _ = try await repo.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")

        await XCTAssertThrowsErrorAsync(try await repo.regenerateJoinCode(teamId: team.id, by: mate)) {
            XCTAssertEqual($0 as? TeamError, .notAuthorised)
        }
    }

    // MARK: - Role openness

    func testUnknownRolesSurviveRatherThanCrash() async throws {
        let future = TeamRole(rawValue: "treasurer")
        XCTAssertEqual(future.rawValue, "treasurer")
        XCTAssertEqual(future.label, "Treasurer")
        XCTAssertNotEqual(future, .owner)
    }
}

final class MoneyTests: XCTestCase {
    func testFormattingWholeAndPartPounds() async throws {
        XCTAssertEqual(Money.string(0), "£0")
        XCTAssertEqual(Money.string(200), "£2")
        XCTAssertEqual(Money.string(250), "£2.50")
        XCTAssertEqual(Money.string(205), "£2.05")
        XCTAssertEqual(Money.string(1000), "£10")
        XCTAssertEqual(Money.string(-250), "-£2.50")
    }

    func testParsingWhatPeopleActuallyType() async throws {
        XCTAssertEqual(Money.pence(from: "2"), 200)
        XCTAssertEqual(Money.pence(from: "2.50"), 250)
        XCTAssertEqual(Money.pence(from: "2,50"), 250)
        XCTAssertEqual(Money.pence(from: "£3"), 300)
        XCTAssertEqual(Money.pence(from: " 0.05 "), 5)
        XCTAssertNil(Money.pence(from: ""))
        XCTAssertNil(Money.pence(from: "abc"))
        XCTAssertNil(Money.pence(from: "-1"))
    }

    /// Parsing runs on every keystroke, so anything a keyboard or a paste can
    /// produce must come back nil rather than trap converting to Int.
    func testOutOfRangeInputIsRejectedRatherThanCrashing() {
        XCTAssertNil(Money.pence(from: "100000000000000000"))
        XCTAssertNil(Money.pence(from: "1e300"))
        XCTAssertNil(Money.pence(from: "inf"))
        XCTAssertNil(Money.pence(from: "nan"))
        XCTAssertNil(Money.pence(from: "10000.01"))
        XCTAssertEqual(Money.pence(from: "10000"), Money.maxPence)
    }

    func testRoundTripThroughDisplay() async throws {
        for pence in [0, 5, 99, 100, 250, 1234, 10000] {
            let text = Money.string(pence).replacingOccurrences(of: "£", with: "")
            XCTAssertEqual(Money.pence(from: text), pence, "round trip failed for \(pence)")
        }
    }
}
