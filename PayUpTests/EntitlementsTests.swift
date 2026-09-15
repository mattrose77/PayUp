import XCTest
import SwiftData
@testable import PayUp

/// Lets a test pretend the account is on a different tier. The point of these
/// tests is that the limit is a value read from the provider, not a constant
/// baked into the repository.
private struct StubEntitlementsProvider: EntitlementsProvider {
    let current: Entitlements
}

@MainActor
final class EntitlementsTests: XCTestCase {
    private var container: ModelContainer!

    private let me = "user-me"
    private let mate = "user-mate"

    override func setUpWithError() throws {
        let schema = Schema([
            Player.self, FineType.self, Fine.self, Match.self,
            Team.self, TeamMember.self
        ])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() { container = nil }

    private func repository(maxTeamsOwned: Int? = nil) -> LocalTeamRepository {
        var repo = LocalTeamRepository(context: ModelContext(container))
        if let maxTeamsOwned {
            repo.entitlementsProvider = StubEntitlementsProvider(
                current: Entitlements(maxTeamsOwned: maxTeamsOwned)
            )
        }
        return repo
    }

    // MARK: - The free tier

    func testUserWhoOwnsNothingCanCreateATeam() async throws {
        let repo = repository()
        let hoisted1 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted1, 0)

        let team = try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        XCTAssertEqual(team.name, "Minety FC")
        let hoisted2 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted2, 1)
    }

    func testOwnerAtTheLimitCannotCreateASecondTeam() async throws {
        let repo = repository()
        try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        await XCTAssertThrowsErrorAsync(
            try await repo.createTeam(name: "Minety Reserves", userId: me, displayName: "Matt")
        ) { XCTAssertEqual($0 as? TeamError, .teamLimitReached(limit: 1)) }

        let hoisted3 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted3, 1)
    }

    // MARK: - Admin seats are free

    func testAdminOnSomeoneElsesTeamCanStillCreateTheirOwn() async throws {
        let repo = repository()
        let theirs = try await repo.createTeam(name: "Their Club", userId: mate, displayName: "Sam")
        try await repo.joinTeam(code: theirs.joinCode, userId: me, displayName: "Matt")

        let hoisted4 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted4, 0, "an admin seat is not an owned team")

        let mine = try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        let hoisted5 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted5, 1)
        let hoisted6 = try await repo.teams(forUser: me).count
        XCTAssertEqual(hoisted6, 2, "member of both")
        XCTAssertNotEqual(mine.id, theirs.id)
    }

    func testOwnerCanStillJoinAnotherTeamAsAdmin() async throws {
        let repo = repository()
        try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")
        let theirs = try await repo.createTeam(name: "Their Club", userId: mate, displayName: "Sam")

        try await repo.joinTeam(code: theirs.joinCode, userId: me, displayName: "Matt")

        let hoisted7 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted7, 1, "joining didn't consume an owner slot")
        let hoisted8 = try await repo.teams(forUser: me).count
        XCTAssertEqual(hoisted8, 2)
    }

    // MARK: - Freeing a slot

    func testDeletingAnOwnedTeamFreesTheSlot() async throws {
        let repo = repository()
        let first = try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        await XCTAssertThrowsErrorAsync(
            try await repo.createTeam(name: "Second", userId: me, displayName: "Matt")
        )

        try await repo.deleteTeam(teamId: first.id, by: me)
        let hoisted9 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted9, 0)

        let replacement = try await repo.createTeam(name: "Second", userId: me, displayName: "Matt")
        XCTAssertEqual(replacement.name, "Second")
        let hoisted10 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted10, 1)
    }

    func testLeavingSomeoneElsesTeamDoesNotChangeTheOwnedCount() async throws {
        let repo = repository()
        try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")
        let theirs = try await repo.createTeam(name: "Their Club", userId: mate, displayName: "Sam")
        try await repo.joinTeam(code: theirs.joinCode, userId: me, displayName: "Matt")

        try await repo.leaveTeam(teamId: theirs.id, userId: me)

        let hoisted11 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted11, 1, "leaving frees nothing, it cost nothing")
        await XCTAssertThrowsErrorAsync(
            try await repo.createTeam(name: "Second", userId: me, displayName: "Matt")
        ) { XCTAssertEqual($0 as? TeamError, .teamLimitReached(limit: 1)) }
    }

    // MARK: - The limit is a value, not a constant

    func testLimitIsReadFromTheProvider() async throws {
        let repo = repository(maxTeamsOwned: 3)
        XCTAssertEqual(repo.entitlements.maxTeamsOwned, 3)

        for index in 1...3 {
            let team = try await repo.createTeam(name: "Team \(index)", userId: me, displayName: "Matt")
            XCTAssertEqual(team.name, "Team \(index)")
        }
        let hoisted12 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted12, 3)

        await XCTAssertThrowsErrorAsync(
            try await repo.createTeam(name: "Team 4", userId: me, displayName: "Matt")
        ) { XCTAssertEqual($0 as? TeamError, .teamLimitReached(limit: 3)) }

        let hoisted13 = try await repo.ownedTeamCount(forUser: me)
        XCTAssertEqual(hoisted13, 3, "the rejected team wasn't created")
    }

    func testDefaultProviderIsTheFreeTier() async throws {
        XCTAssertEqual(repository().entitlements, .free)
        XCTAssertEqual(Entitlements.free.maxTeamsOwned, 1)
    }
}
