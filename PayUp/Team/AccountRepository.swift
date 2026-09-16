import Foundation

enum AccountError: LocalizedError, Equatable {
    case wrongPassword
    case notSignedIn
    /// The remaining member can't be promoted because they already own a team.
    /// The server refuses the whole handover rather than letting the
    /// entitlement trigger roll it back halfway.
    case successorOwnsTeam(name: String?)
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return "That password isn't right."
        case .notSignedIn:
            return "You're not signed in."
        case .successorOwnsTeam(let name):
            let who = name ?? "The other member"
            return "\(who) already owns a team, so they can't take this one over. "
                + "Your account hasn't been deleted. Ask them to hand their own team "
                + "over or delete it, then try again."
        case .serverRejected(let message):
            return message
        }
    }
}

/// What the server reports it actually did. The client works out which case it
/// expects for the confirmation copy; this is the server's own answer, and
/// it's the one worth trusting.
enum AccountDeletionOutcome: String, Codable, Sendable {
    case handedOver = "handed_over"
    case teamDeleted = "team_deleted"
    case leftTeam = "left_team"
    case accountOnly = "account_only"

    /// Used when a user is somehow in several teams: the worst thing that
    /// happened is what gets reported.
    var severity: Int {
        switch self {
        case .accountOnly: return 0
        case .leftTeam: return 1
        case .handedOver: return 2
        case .teamDeleted: return 3
        }
    }
}

protocol AccountRepository {
    /// Supabase won't delete a user on a stale session, and requiring the
    /// password stops an unlocked, unattended phone being enough to wipe a
    /// season.
    func reauthenticate(email: String, password: String) async throws

    /// One RPC, one transaction — see `delete_account()` in the database.
    /// Doing this as a sequence of client calls risks a half-deleted team or a
    /// team with no owner if any step fails.
    @discardableResult
    func deleteAccount() async throws -> AccountDeletionOutcome
}
