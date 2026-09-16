import XCTest
import SwiftData
@testable import PayUp

/// The app used to sit on a spinner after signing in and after joining with a
/// code, recovering only on a force-quit. The cause was structural: the data
/// store was built only when *auth* changed, so a team arriving later left the
/// UI in a loading branch nothing updated.
///
/// These pin the rule that replaced it — every entry point ends in a terminal
/// phase, and `.ready` always carries a store for the current team.
@MainActor
final class SessionPhaseTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var data: LocalStore!

    private let me = "user-me"
    private let mate = "user-mate"

    override func setUpWithError() throws {
        let schema = Schema([Team.self, TeamMember.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        data = LocalStore()
    }

    override func tearDown() {
        container = nil; context = nil; data = nil
    }

    private func makeSession(
        userId: String,
        repository: TeamRepository? = nil
    ) -> TeamSession {
        let store = data!
        return TeamSession(
            repository: repository ?? LocalTeamRepository(context: context),
            userId: userId,
            makeDataStore: { teamId, userId in
                TeamDataStore(
                    teamId: teamId,
                    userId: userId,
                    players: LocalPlayerRepository(store: store),
                    fineTypes: LocalFineTypeRepository(store: store),
                    matches: LocalMatchRepository(store: store),
                    fines: LocalFineRepository(store: store)
                )
            }
        )
    }

    // MARK: - Entry point 1: sign-in

    func testSignInWithATeamReachesReadyWithAStore() async throws {
        let repo = LocalTeamRepository(context: context)
        let team = try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        let session = makeSession(userId: me)
        await session.refresh()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.team?.id, team.id)
        XCTAssertEqual(session.dataStore?.teamId, team.id, "the store must belong to the resolved team")
    }

    func testSignInWithNoTeamReachesNeedsTeam() async throws {
        let session = makeSession(userId: me)
        await session.refresh()

        XCTAssertEqual(session.phase, .needsTeam)
        XCTAssertNil(session.dataStore, "no team means no store to hand the tabs")
    }

    // MARK: - Entry point 2: joining and creating

    /// The exact hang: the team arrives without auth changing, so nothing used
    /// to build a store and the app sat on a spinner until it was force-quit.
    func testJoiningWithACodeReachesReadyWithAStore() async throws {
        let repo = LocalTeamRepository(context: context)
        let team = try await repo.createTeam(name: "Minety FC", userId: mate, displayName: "Sam")

        let session = makeSession(userId: me)
        await session.refresh()
        XCTAssertEqual(session.phase, .needsTeam)

        try await session.joinTeam(code: team.joinCode, displayName: "Matt")

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.team?.id, team.id)
        XCTAssertEqual(session.dataStore?.teamId, team.id)
    }

    func testCreatingATeamReachesReadyWithAStore() async throws {
        let session = makeSession(userId: me)
        await session.refresh()
        XCTAssertEqual(session.phase, .needsTeam)

        try await session.createTeam(name: "Minety FC", displayName: "Matt")

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.dataStore?.teamId, session.team?.id)
    }

    // MARK: - Terminal states

    /// The property that matters: whatever happens, the UI stops spinning.
    func testEveryEntryPointEndsTerminal() async throws {
        let repo = LocalTeamRepository(context: context)
        let team = try await repo.createTeam(name: "Minety FC", userId: mate, displayName: "Sam")

        // Signed in, no team.
        let joiner = makeSession(userId: me)
        await joiner.refresh()
        XCTAssertTrue(joiner.phase.isTerminal, "sign-in with no team")

        // Joined.
        try await joiner.joinTeam(code: team.joinCode, displayName: "Matt")
        XCTAssertTrue(joiner.phase.isTerminal, "after joining")

        // Signed in, with a team.
        let returning = makeSession(userId: me)
        await returning.refresh()
        XCTAssertTrue(returning.phase.isTerminal, "sign-in with a team")

        // A failing server.
        let broken = makeSession(userId: me, repository: FailingTeamRepository())
        await broken.refresh()
        XCTAssertTrue(broken.phase.isTerminal, "a failed fetch must still be terminal")
    }

    func testAFailedFetchSurfacesAsFailedNotAsNoTeam() async {
        let session = makeSession(userId: me, repository: FailingTeamRepository())
        await session.refresh()

        XCTAssertEqual(session.phase, .failed(TeamError.notAuthorised.localizedDescription))
        XCTAssertNotEqual(
            session.phase, .needsTeam,
            "a failure that looks like 'no team' would invite a second team to be created"
        )
    }

    /// The error state offers a retry, so it has to actually recover.
    func testRetryAfterAFailureReachesReady() async throws {
        let repo = LocalTeamRepository(context: context)
        let team = try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        let flaky = FlakyTeamRepository(inner: repo)
        let session = makeSession(userId: me, repository: flaky)

        await session.refresh()
        XCTAssertEqual(session.phase, .failed(TeamError.notAuthorised.localizedDescription))

        flaky.healed = true
        await session.refresh()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.dataStore?.teamId, team.id)
    }

    // MARK: - Store identity

    func testSwitchingAccountDropsTheStore() async throws {
        let repo = LocalTeamRepository(context: context)
        _ = try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        let session = makeSession(userId: me)
        await session.refresh()
        XCTAssertNotNil(session.dataStore)

        // Signing in as someone else must not leave the previous team's store.
        session.adopt(userId: "somebody-else")
        XCTAssertNil(session.dataStore)
        XCTAssertEqual(session.phase, .idle)

        await session.refresh()
        XCTAssertEqual(session.phase, .needsTeam)
        XCTAssertNil(session.dataStore)
    }

    /// Refreshing the same team shouldn't throw its loaded data away.
    func testRefreshingKeepsTheSameStoreForTheSameTeam() async throws {
        let repo = LocalTeamRepository(context: context)
        _ = try await repo.createTeam(name: "Minety FC", userId: me, displayName: "Matt")

        let session = makeSession(userId: me)
        await session.refresh()
        let first = session.dataStore
        await session.refresh()

        XCTAssertTrue(first === session.dataStore, "the store should survive a refresh of the same team")
    }
}

// MARK: - Doubles

private struct FailingTeamRepository: TeamRepository {
    var entitlements: Entitlements { .free }
    func ownedTeamCount(forUser userId: String) async throws -> Int { throw TeamError.notAuthorised }
    func teams(forUser userId: String) async throws -> [Team] { throw TeamError.notAuthorised }
    func members(of teamId: UUID) async throws -> [TeamMember] { throw TeamError.notAuthorised }
    func createTeam(name: String, userId: String, displayName: String) async throws -> Team {
        throw TeamError.notAuthorised
    }
    func joinTeam(code: String, userId: String, displayName: String) async throws -> Team {
        throw TeamError.notAuthorised
    }
    func rename(teamId: UUID, to name: String) async throws { throw TeamError.notAuthorised }
    func regenerateJoinCode(teamId: UUID, by userId: String) async throws -> String {
        throw TeamError.notAuthorised
    }
    func removeMember(_ memberId: UUID, by userId: String) async throws { throw TeamError.notAuthorised }
    func leaveTeam(teamId: UUID, userId: String) async throws { throw TeamError.notAuthorised }
    func deleteTeam(teamId: UUID, by userId: String) async throws { throw TeamError.notAuthorised }
}

/// Fails until `healed`, so a retry can be shown to actually work.
private final class FlakyTeamRepository: TeamRepository, @unchecked Sendable {
    let inner: LocalTeamRepository
    var healed = false

    init(inner: LocalTeamRepository) { self.inner = inner }

    private func gate() throws {
        if !healed { throw TeamError.notAuthorised }
    }

    var entitlements: Entitlements { inner.entitlements }
    func ownedTeamCount(forUser userId: String) async throws -> Int {
        try gate(); return try await inner.ownedTeamCount(forUser: userId)
    }
    func teams(forUser userId: String) async throws -> [Team] {
        try gate(); return try await inner.teams(forUser: userId)
    }
    func members(of teamId: UUID) async throws -> [TeamMember] {
        try gate(); return try await inner.members(of: teamId)
    }
    func createTeam(name: String, userId: String, displayName: String) async throws -> Team {
        try gate(); return try await inner.createTeam(name: name, userId: userId, displayName: displayName)
    }
    func joinTeam(code: String, userId: String, displayName: String) async throws -> Team {
        try gate(); return try await inner.joinTeam(code: code, userId: userId, displayName: displayName)
    }
    func rename(teamId: UUID, to name: String) async throws {
        try gate(); try await inner.rename(teamId: teamId, to: name)
    }
    func regenerateJoinCode(teamId: UUID, by userId: String) async throws -> String {
        try gate(); return try await inner.regenerateJoinCode(teamId: teamId, by: userId)
    }
    func removeMember(_ memberId: UUID, by userId: String) async throws {
        try gate(); try await inner.removeMember(memberId, by: userId)
    }
    func leaveTeam(teamId: UUID, userId: String) async throws {
        try gate(); try await inner.leaveTeam(teamId: teamId, userId: userId)
    }
    func deleteTeam(teamId: UUID, by userId: String) async throws {
        try gate(); try await inner.deleteTeam(teamId: teamId, by: userId)
    }
}
