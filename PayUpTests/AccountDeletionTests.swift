import XCTest
import SwiftData
@testable import PayUp

/// Account deletion is irreversible and ships to satisfy App Store guideline
/// 5.1.1(v), so every branch is pinned here: what each situation destroys, what
/// it must leave alone, and what has to be true before the button works at all.
@MainActor
final class AccountDeletionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var teams: LocalTeamRepository!
    private var data: LocalStore!

    private let owner = "user-owner"
    private let mate = "user-mate"
    private let email = "keeper@minety.example"
    private let password = "correct-horse"

    override func setUpWithError() throws {
        let schema = Schema([Team.self, TeamMember.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        teams = LocalTeamRepository(context: context)
        data = LocalStore()
    }

    override func tearDown() {
        container = nil; context = nil; teams = nil; data = nil
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeTeam(withSecondMember: Bool = false) async throws -> Team {
        let team = try await teams.createTeam(name: "Minety FC", userId: owner, displayName: "Matt")
        if withSecondMember {
            _ = try await teams.joinTeam(code: team.joinCode, userId: mate, displayName: "Sam")
        }
        return team
    }

    /// A squad with a matchday and a fine on it, so a cascade has something to
    /// actually destroy.
    private func fillTeam(_ teamId: UUID) async {
        let player = Player(
            id: UUID(), teamId: teamId, name: "Jamie Vasey",
            active: true, userId: nil, createdAt: Date()
        )
        let type = FineType(
            id: UUID(), teamId: teamId, name: "Late arrival",
            amountPence: 200, active: true, sortOrder: 0, createdAt: Date()
        )
        let match = Match(
            id: UUID(), teamId: teamId, opponent: "Crown FC", playedOn: Date(),
            isComplete: false, completedAt: nil, itemOfTheWeek: "", createdAt: Date()
        )
        let fine = Fine(
            id: UUID(), teamId: teamId, matchId: match.id, playerId: player.id,
            fineTypeId: type.id, description: "Late arrival", amountPence: 200,
            paid: false, paidAt: nil, createdBy: owner, createdAt: Date()
        )
        await data.insert(player)
        await data.insert(type)
        await data.insert(match)
        await data.insert(fine)
    }

    private func repository(for userId: String) -> LocalAccountRepository {
        LocalAccountRepository(
            context: context, data: data, userId: userId,
            email: email, password: password
        )
    }

    private func deletionCase(for userId: String, team: Team?) async throws -> AccountDeletionCase {
        let members = team == nil ? [] : try await teams.members(of: team!.id)
        return AccountDeletionCase.resolve(team: team, members: members, userId: userId)
    }

    // MARK: - Case 1: owner with a second member

    func testOwnerWithSecondMemberHandsTheTeamOver() async throws {
        let team = try await makeTeam(withSecondMember: true)
        await fillTeam(team.id)

        let resolved = try await deletionCase(for: owner, team: team)
        XCTAssertEqual(resolved, .handsOver(team: "Minety FC", successor: "Sam"))

        let outcome = try await repository(for: owner).deleteAccount()
        XCTAssertEqual(outcome, .handedOver)
    }

    func testPromotionLeavesExactlyOneOwner() async throws {
        let team = try await makeTeam(withSecondMember: true)
        try await repository(for: owner).deleteAccount()

        let roster = try await teams.members(of: team.id)
        XCTAssertEqual(roster.count, 1, "the leaving owner's membership should be gone")
        XCTAssertEqual(roster.filter { $0.role == .owner }.count, 1, "the team needs exactly one owner")
        XCTAssertEqual(roster.first?.userId, mate)
    }

    func testHandoverLeavesTheTeamAndItsDataAlone() async throws {
        let team = try await makeTeam(withSecondMember: true)
        await fillTeam(team.id)

        try await repository(for: owner).deleteAccount()

        let surviving = try await teams.teams(forUser: mate)
        XCTAssertEqual(surviving.count, 1)
        let counts = await data.counts(teamId: team.id)
        XCTAssertEqual(counts, TeamContents(players: 1, matches: 1, fines: 1))
    }

    // MARK: - Case 2: sole owner

    func testSoleOwnerDeletesTheTeamAndAllItsData() async throws {
        let team = try await makeTeam()
        await fillTeam(team.id)

        let resolved = try await deletionCase(for: owner, team: team)
        XCTAssertTrue(resolved.isDestructive)
        XCTAssertEqual(resolved.teamNameToConfirm, "Minety FC")

        let outcome = try await repository(for: owner).deleteAccount()
        XCTAssertEqual(outcome, .teamDeleted)

        let remainingTeams = try await teams.teams(forUser: owner)
        let remainingMembers = try await teams.members(of: team.id)
        XCTAssertTrue(remainingTeams.isEmpty)
        XCTAssertTrue(remainingMembers.isEmpty)
        let counts = await data.counts(teamId: team.id)
        XCTAssertEqual(counts, TeamContents(), "squad, matchdays and fines should all be gone")
    }

    /// `fines.player_id` is `on delete restrict`, so the order isn't cosmetic:
    /// deleting players first would be refused by the database.
    func testFinesAreClearedBeforePlayers() async throws {
        let team = try await makeTeam()
        await fillTeam(team.id)
        try await repository(for: owner).deleteAccount()

        let remainingFines = await data.fines.count
        let remainingPlayers = await data.players.count
        XCTAssertEqual(remainingFines, 0)
        XCTAssertEqual(remainingPlayers, 0)
    }

    // MARK: - Case 3: admin

    func testAdminDeletionLeavesTheTeamIntact() async throws {
        let team = try await makeTeam(withSecondMember: true)
        await fillTeam(team.id)

        let resolved = try await deletionCase(for: mate, team: team)
        XCTAssertEqual(resolved, .leavesTeam(team: "Minety FC"))
        XCTAssertFalse(resolved.isDestructive)

        let outcome = try await repository(for: mate).deleteAccount()
        XCTAssertEqual(outcome, .leftTeam)

        let roster = try await teams.members(of: team.id)
        XCTAssertEqual(roster.count, 1)
        XCTAssertEqual(roster.first?.userId, owner)
        XCTAssertEqual(roster.first?.role, .owner, "the owner should still be the owner")

        let counts = await data.counts(teamId: team.id)
        XCTAssertEqual(counts, TeamContents(players: 1, matches: 1, fines: 1))
    }

    // MARK: - Case 4: no team

    func testNoTeamIsAccountOnly() async throws {
        let resolved = try await deletionCase(for: owner, team: nil)
        XCTAssertEqual(resolved, .accountOnly)
        XCTAssertFalse(resolved.isDestructive)
        XCTAssertNil(resolved.teamNameToConfirm)

        let outcome = try await repository(for: owner).deleteAccount()
        XCTAssertEqual(outcome, .accountOnly)
    }

    /// A member of somebody else's team who has been removed shouldn't be told
    /// a team is about to be destroyed.
    func testResolvingIgnoresATeamTheUserIsNoLongerIn() async throws {
        let team = try await makeTeam()
        let roster = try await teams.members(of: team.id)
        let resolved = AccountDeletionCase.resolve(team: team, members: roster, userId: "someone-else")
        XCTAssertEqual(resolved, .accountOnly)
    }

    // MARK: - Confirmation gate

    func testTypedTeamNameMustMatchBeforeDestructiveDeleteIsEnabled() {
        let destructive = AccountDeletionCase.deletesTeam(team: "Minety FC", contents: TeamContents())

        XCTAssertFalse(DeleteAccountForm.canDelete(destructive, typedTeamName: "", password: "pw"))
        XCTAssertFalse(DeleteAccountForm.canDelete(destructive, typedTeamName: "Minety", password: "pw"))
        XCTAssertFalse(DeleteAccountForm.canDelete(destructive, typedTeamName: "Crown FC", password: "pw"))
        XCTAssertTrue(DeleteAccountForm.canDelete(destructive, typedTeamName: "Minety FC", password: "pw"))
        // A speed bump against a mistap, not a spelling test.
        XCTAssertTrue(DeleteAccountForm.canDelete(destructive, typedTeamName: "  minety fc ", password: "pw"))
    }

    func testPasswordIsRequiredInEveryCase() {
        let cases: [AccountDeletionCase] = [
            .handsOver(team: "Minety FC", successor: "Sam"),
            .deletesTeam(team: "Minety FC", contents: TeamContents()),
            .leavesTeam(team: "Minety FC"),
            .accountOnly
        ]
        for deletionCase in cases {
            XCTAssertFalse(
                DeleteAccountForm.canDelete(deletionCase, typedTeamName: "Minety FC", password: ""),
                "\(deletionCase) should not be deletable without a password"
            )
        }
    }

    func testNonDestructiveCasesDoNotAskForATeamName() {
        for deletionCase in [AccountDeletionCase.leavesTeam(team: "Minety FC"), .accountOnly] {
            XCTAssertTrue(DeleteAccountForm.canDelete(deletionCase, typedTeamName: "", password: "pw"))
        }
    }

    // MARK: - The flow

    private func flow(
        _ deletionCase: AccountDeletionCase,
        account: LocalAccountRepository,
        onFinish: @escaping @MainActor () -> Void = {}
    ) -> AccountDeletionFlow {
        AccountDeletionFlow(
            deletionCase: deletionCase, account: account, email: email
        ) { onFinish() }
    }

    func testWrongPasswordBlocksDeletion() async throws {
        let team = try await makeTeam()
        await fillTeam(team.id)
        let account = repository(for: owner)
        var finished = false

        let subject = flow(
            .deletesTeam(team: "Minety FC", contents: TeamContents()),
            account: account,
            onFinish: { finished = true }
        )
        subject.typedTeamName = "Minety FC"
        subject.password = "not-my-password"
        await subject.delete()

        XCTAssertEqual(subject.phase, .failed(AccountError.wrongPassword.localizedDescription))
        XCTAssertEqual(account.deleteCount, 0, "nothing should reach the delete RPC")
        XCTAssertFalse(account.accountDeleted)
        XCTAssertFalse(finished, "the session must survive a failed attempt")
        let survivingTeams = try await teams.teams(forUser: owner)
        XCTAssertEqual(survivingTeams.count, 1, "the team must survive")
        let counts = await data.counts(teamId: team.id)
        XCTAssertEqual(counts, TeamContents(players: 1, matches: 1, fines: 1))
    }

    func testFailedAttemptClearsThePasswordAndCanBeRetried() async throws {
        try await makeTeam()
        let account = repository(for: owner)
        let subject = flow(.deletesTeam(team: "Minety FC", contents: TeamContents()), account: account)

        subject.typedTeamName = "Minety FC"
        subject.password = "wrong"
        await subject.delete()
        XCTAssertTrue(subject.password.isEmpty)
        XCTAssertFalse(subject.canDelete, "an empty password should re-disable the button")

        subject.password = password
        await subject.delete()
        XCTAssertEqual(subject.phase, .deleted(.teamDeleted))
    }

    func testLocalStateAndSessionAreClearedAfterwards() async throws {
        try await makeTeam()
        let account = repository(for: owner)
        var finished = 0

        let subject = flow(
            .deletesTeam(team: "Minety FC", contents: TeamContents()),
            account: account,
            onFinish: { finished += 1 }
        )
        subject.typedTeamName = "Minety FC"
        subject.password = password
        await subject.delete()

        XCTAssertEqual(subject.phase, .deleted(.teamDeleted))
        XCTAssertEqual(finished, 1, "sign-out and local wipe run exactly once, after the server confirms")
        XCTAssertTrue(subject.password.isEmpty, "the password must not linger in memory")
    }

    /// The teardown itself: nothing the next launch could restore.
    func testLocalStateClearRemovesEverythingTheAppStored() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "account-deletion-tests"))
        defer { suite.removePersistentDomain(forName: "account-deletion-tests") }

        suite.set("Minety FC", forKey: Club.storageKey)
        suite.set("Pay up by Thursday", forKey: Club.closingKey)
        suite.set("local-id", forKey: CurrentUser.idKey)
        suite.set("Matt", forKey: CurrentUser.nameKey)

        LocalState.clear(suite)

        for key in LocalState.keys {
            XCTAssertNil(suite.object(forKey: key), "\(key) should not survive account deletion")
        }
    }

    func testClearingTheTeamStoreLeavesNothingBehind() async throws {
        try await makeTeam(withSecondMember: true)
        LocalState.clearTeamStore(context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Team>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TeamMember>()).isEmpty)
    }

    // MARK: - Successor already owns a team

    /// The server refuses the handover outright rather than letting the
    /// entitlement trigger roll the transaction back halfway.
    func testHandoverRefusedWhenSuccessorAlreadyOwnsATeam() async throws {
        let team = try await makeTeam(withSecondMember: true)
        await fillTeam(team.id)
        let account = repository(for: owner)
        account.successorOwnsAnotherTeam = true
        var finished = false

        let subject = flow(
            .handsOver(team: "Minety FC", successor: "Sam"),
            account: account,
            onFinish: { finished = true }
        )
        subject.password = password
        await subject.delete()

        XCTAssertEqual(
            subject.phase,
            .failed(AccountError.successorOwnsTeam(name: "Sam").localizedDescription)
        )
        XCTAssertFalse(finished, "a refused handover must leave the session alone")

        // Nothing moved: same two members, same owner, same data.
        let roster = try await teams.members(of: team.id)
        XCTAssertEqual(roster.count, 2)
        XCTAssertEqual(roster.first { $0.role == .owner }?.userId, owner)
        let counts = await data.counts(teamId: team.id)
        XCTAssertEqual(counts, TeamContents(players: 1, matches: 1, fines: 1))
    }

    func testSuccessorOwnsTeamMessageNamesThem() {
        let named = AccountError.successorOwnsTeam(name: "Sam").localizedDescription
        XCTAssertTrue(named.hasPrefix("Sam already owns a team"))
        XCTAssertTrue(named.contains("hasn't been deleted"), "the user needs to know they still have an account")

        // No name in the detail is still a usable sentence.
        let anonymous = AccountError.successorOwnsTeam(name: nil).localizedDescription
        XCTAssertTrue(anonymous.hasPrefix("The other member already owns a team"))
    }

    /// The exact payload the live server returns, captured from a real refusal:
    /// {"code":"23514","message":"successor_owns_team","details":"Test C"}
    func testSuccessorRefusalIsMappedFromTheLiveServerError() {
        XCTAssertEqual(
            PostgresErrorMapper.accountError(from: "successor_owns_team", detail: "Test C"),
            .successorOwnsTeam(name: "Test C")
        )
        XCTAssertEqual(
            AccountError.successorOwnsTeam(name: "Test C").localizedDescription,
            "Test C already owns a team, so they can't take this one over. "
                + "Your account hasn't been deleted. Ask them to hand their own team "
                + "over or delete it, then try again."
        )
    }

    func testSuccessorRefusalSurvivesPostgresWrappingTheMessage() {
        XCTAssertEqual(
            PostgresErrorMapper.accountError(
                from: #"PostgrestError(message: "successor_owns_team", code: "23514")"#,
                detail: "Sam Whittaker"
            ),
            .successorOwnsTeam(name: "Sam Whittaker")
        )
        XCTAssertEqual(
            PostgresErrorMapper.accountError(from: "SUCCESSOR_OWNS_TEAM", detail: nil),
            .successorOwnsTeam(name: nil)
        )
    }

    /// Display names are user-entered. Punctuation in one must survive intact —
    /// showing someone else's name would be worse than showing an odd one.
    func testSuccessorNameIsTakenVerbatim() {
        XCTAssertEqual(PostgresErrorMapper.successorName(in: "Test C"), "Test C")
        XCTAssertEqual(PostgresErrorMapper.successorName(in: "  Test C  "), "Test C")
        XCTAssertEqual(PostgresErrorMapper.successorName(in: "Sam: the keeper"), "Sam: the keeper")
        XCTAssertEqual(PostgresErrorMapper.successorName(in: "O'Neill"), "O'Neill")
    }

    /// A detail that isn't a name shouldn't be pasted into a sentence.
    func testSuccessorNameRejectsNothingAndProse() {
        XCTAssertNil(PostgresErrorMapper.successorName(in: nil))
        XCTAssertNil(PostgresErrorMapper.successorName(in: "   "))
        XCTAssertNil(PostgresErrorMapper.successorName(
            in: "the remaining member of this team already owns a team of their own and cannot be promoted"
        ))
    }

    func testUnknownServerErrorsStillSurface() {
        XCTAssertEqual(
            PostgresErrorMapper.accountError(from: "some_new_rule", detail: nil),
            .serverRejected("some_new_rule")
        )
    }

    // MARK: - Copy

    /// The destructive case is the one that must not be softened.
    func testDestructiveCopyNamesTheTeamAndSaysItCannotBeUndone() {
        let deletionCase = AccountDeletionCase.deletesTeam(
            team: "Minety FC",
            contents: TeamContents(players: 14, matches: 3, fines: 22)
        )
        XCTAssertTrue(deletionCase.title.contains("Minety FC"))
        XCTAssertTrue(deletionCase.message.contains("Minety FC"))
        XCTAssertTrue(deletionCase.message.contains("14 players"))
        XCTAssertTrue(deletionCase.message.contains("3 matchdays"))
        XCTAssertTrue(deletionCase.message.contains("22 fines"))
        XCTAssertTrue(deletionCase.message.lowercased().contains("permanent"))
        XCTAssertTrue(deletionCase.message.lowercased().contains("no undo"))
    }

    /// The other three must not imply the team's data is at risk, because it
    /// isn't.
    func testSurvivingTeamCopyPromisesTheDataStays() {
        let handover = AccountDeletionCase.handsOver(team: "Minety FC", successor: "Sam")
        XCTAssertTrue(handover.message.contains("Sam"))
        XCTAssertTrue(handover.message.contains("carries on"))

        let admin = AccountDeletionCase.leavesTeam(team: "Minety FC")
        XCTAssertTrue(admin.message.contains("unaffected"))

        for deletionCase in [handover, admin, .accountOnly] {
            XCTAssertNil(deletionCase.teamNameToConfirm)
            XCTAssertFalse(deletionCase.isDestructive)
        }
    }
}
