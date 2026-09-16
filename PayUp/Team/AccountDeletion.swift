import Foundation

/// What deleting this account actually destroys. Every word of the
/// confirmation is derived from this, so the copy can't promise a team
/// survives when it's about to be deleted with it.
///
/// Mirrors the four branches of `delete_account()` in Postgres. The server
/// decides what really happens; this decides what the user is told first.
enum AccountDeletionCase: Equatable {
    /// Owner with a second member. The team carries on under them.
    case handsOver(team: String, successor: String)
    /// Sole owner. The team and everything in it goes with the account.
    case deletesTeam(team: String, contents: TeamContents)
    /// Admin. Only the membership goes; the team is untouched.
    case leavesTeam(team: String)
    /// No team at all.
    case accountOnly

    /// Picks the successor the same way the server does — earliest joined —
    /// so the name shown is the one that actually gets promoted.
    static func resolve(
        team: Team?,
        members: [TeamMember],
        userId: String,
        contents: TeamContents = TeamContents()
    ) -> AccountDeletionCase {
        guard let team, let me = members.first(where: { UserID.matches($0.userId, userId) }) else {
            return .accountOnly
        }
        guard me.role == .owner else { return .leavesTeam(team: team.name) }

        let others = members
            .filter { !UserID.matches($0.userId, userId) }
            .sorted { $0.joinedAt < $1.joinedAt }
        guard let successor = others.first else {
            return .deletesTeam(team: team.name, contents: contents)
        }
        return .handsOver(team: team.name, successor: successor.displayName)
    }

    /// Only the sole-owner case destroys anything that can't be got back, so
    /// only that one asks for the team name to be typed out.
    var isDestructive: Bool {
        if case .deletesTeam = self { return true }
        return false
    }

    /// The name that has to be typed to arm the button, if any.
    var teamNameToConfirm: String? {
        if case .deletesTeam(let team, _) = self { return team }
        return nil
    }
}

/// What's in the team, so the destructive confirmation can say what is lost
/// rather than gesturing at "your data".
struct TeamContents: Equatable {
    var players = 0
    var matches = 0
    var fines = 0

    var isEmpty: Bool { players == 0 && matches == 0 && fines == 0 }

    var sentence: String? {
        guard !isEmpty else { return nil }
        let parts = [
            players > 0 ? "\(players) player\(players == 1 ? "" : "s")" : nil,
            matches > 0 ? "\(matches) matchday\(matches == 1 ? "" : "s")" : nil,
            fines > 0 ? "\(fines) fine\(fines == 1 ? "" : "s")" : nil
        ].compactMap { $0 }
        return parts.formatted(.list(type: .and))
    }
}

/// The confirmation's words. Separate from the view so the promises made in
/// each case are testable.
extension AccountDeletionCase {
    var title: String {
        switch self {
        case .deletesTeam(let team, _): return "Delete your account and \(team)?"
        default: return "Delete your account?"
        }
    }

    var message: String {
        switch self {
        case .handsOver(let team, let successor):
            return "\(successor) becomes the owner of \(team) and it carries on without you. "
                + "The squad, every matchday and all the fines stay exactly as they are.\n\n"
                + "Your account is deleted permanently."

        case .deletesTeam(let team, let contents):
            var text = "You're the only member, so \(team) is deleted along with your account"
            if let inventory = contents.sentence {
                text += " — \(inventory), all of it."
            } else {
                text += "."
            }
            return text + "\n\nThis is permanent. Nothing can be recovered afterwards, "
                + "by you or by anyone else. There is no undo."

        case .leavesTeam(let team):
            return "\(team) and everything in it stays with its owner — the squad, the "
                + "matchdays and the fines are unaffected. Only your access to it goes.\n\n"
                + "Your account is deleted permanently."

        case .accountOnly:
            return "Your account is deleted permanently. You're not in a team, so there's "
                + "no squad or fine history to lose."
        }
    }

    var confirmTitle: String {
        switch self {
        case .deletesTeam(let team, _): return "Delete \(team) and my account"
        default: return "Delete my account"
        }
    }
}

/// Gate on the confirm button. Pure so the "typed name must match" rule is
/// provable without driving the UI.
enum DeleteAccountForm {
    static func canDelete(
        _ deletionCase: AccountDeletionCase,
        typedTeamName: String,
        password: String
    ) -> Bool {
        guard !password.isEmpty else { return false }
        guard let expected = deletionCase.teamNameToConfirm else { return true }
        return matches(typed: typedTeamName, expected: expected)
    }

    /// Forgiving about case and stray spaces — this is a speed bump against a
    /// mistap, not a spelling test.
    static func matches(typed: String, expected: String) -> Bool {
        let left = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return false }
        return left.caseInsensitiveCompare(right) == .orderedSame
    }
}
