import Foundation
import SwiftData

/// In-memory stand-in for `delete_account()`. It exists so the four outcomes,
/// the promotion and the cascade can be proven without a network — the same
/// reason LocalStore mirrors the server's foreign keys.
///
/// This deliberately duplicates the SQL's logic. If that function changes, this
/// has to change with it or the tests stop meaning anything.
@MainActor
final class LocalAccountRepository: AccountRepository {
    private let context: ModelContext
    private let teams: LocalTeamRepository
    private let data: LocalStore
    private let userId: String
    private let email: String
    private let password: String

    private(set) var reauthCount = 0
    private(set) var deleteCount = 0
    /// Set once the account row itself is gone, so tests can tell a blocked
    /// deletion from one that ran.
    private(set) var accountDeleted = false

    /// Simulates the server refusing a handover to someone who already owns a
    /// team of their own.
    var successorOwnsAnotherTeam = false

    init(
        context: ModelContext,
        data: LocalStore,
        userId: String,
        email: String = "keeper@minety.example",
        password: String = "correct-horse"
    ) {
        self.context = context
        self.teams = LocalTeamRepository(context: context)
        self.data = data
        self.userId = userId
        self.email = email
        self.password = password
    }

    func reauthenticate(email: String, password: String) async throws {
        reauthCount += 1
        guard email == self.email else { throw AccountError.notSignedIn }
        guard password == self.password else { throw AccountError.wrongPassword }
    }

    @discardableResult
    func deleteAccount() async throws -> AccountDeletionOutcome {
        deleteCount += 1
        var outcome = AccountDeletionOutcome.accountOnly

        for team in try await teams.teams(forUser: userId) {
            let roster = try await teams.members(of: team.id)
            guard let me = roster.first(where: { UserID.matches($0.userId, userId) }) else { continue }

            if me.role == .owner {
                // Earliest joined takes over — the same pick the SQL makes.
                let successor = roster
                    .filter { !UserID.matches($0.userId, userId) }
                    .sorted { $0.joinedAt < $1.joinedAt }
                    .first
                if let successor {
                    // Refused outright rather than left to the entitlement
                    // trigger, which would roll the whole transaction back.
                    if successorOwnsAnotherTeam {
                        throw AccountError.successorOwnsTeam(name: successor.displayName)
                    }
                    // The departing owner's row goes first: a partial unique
                    // index allows only one owner per team, so promoting while
                    // the old owner is still there violates it.
                    context.delete(me)
                    successor.role = .owner
                    outcome = worse(outcome, .handedOver)
                } else {
                    await data.removeTeam(team.id)
                    context.delete(team)
                    outcome = worse(outcome, .teamDeleted)
                }
            } else {
                outcome = worse(outcome, .leftTeam)
            }

            // Already gone in the handover branch; this covers the rest.
            if !me.isDeleted { context.delete(me) }
        }

        try context.save()
        accountDeleted = true
        return outcome
    }

    private func worse(_ lhs: AccountDeletionOutcome, _ rhs: AccountDeletionOutcome) -> AccountDeletionOutcome {
        lhs.severity >= rhs.severity ? lhs : rhs
    }
}
