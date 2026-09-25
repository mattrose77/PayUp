import Foundation

/// Turns the server's error strings into the TeamError cases the app already
/// speaks. Matches on the message body rather than the status code, because
/// every one of these comes back as the same HTTP failure.
///
/// Pure and synchronous on purpose — this is the layer most likely to break
/// silently when a server rule changes, and it's testable with no network.
enum PostgresErrorMapper {
    static func teamError(from message: String, fallbackLimit: Int) -> TeamError {
        let token = message.lowercased()

        if token.contains("team_full") { return .teamFull }
        if token.contains("team_limit_reached") {
            return .teamLimitReached(limit: limit(in: token) ?? fallbackLimit)
        }
        if token.contains("code_not_found") { return .codeNotFound }
        if token.contains("already_member") { return .alreadyMember }
        // The app has one case for "you lack permission"; the local repository
        // throws the same thing when a non-owner tries an owner-only action.
        if token.contains("not_owner") { return .notAuthorised }

        // PGRST116: an update/select expected exactly one row and got none —
        // in practice the other member deleted it, or it's no longer visible.
        // PostgREST's own wording ("JSON object requested, multiple (or no)
        // rows returned") means nothing to anyone.
        if token.contains("pgrst116") || token.contains("json object requested") {
            return .serverRejected(
                "That's no longer there — it may have been changed or deleted on another phone. Pull down to refresh."
            )
        }

        // 23503 is a foreign key violation. The only restrict-on-delete in the
        // schema is fines -> players, so this is always "they have history".
        if token.contains("23503")
            || token.contains("foreign key")
            || token.contains("violates foreign key constraint") {
            return .playerHasFines
        }

        return .serverRejected(message)
    }

    /// Account deletion has one refusal of its own: the remaining admin can't
    /// be promoted because they already own a team, and the entitlement trigger
    /// would roll the whole transaction back. The server puts the successor's
    /// display name in the error detail so the app can say who it means.
    static func accountError(from message: String, detail: String?) -> AccountError {
        if message.lowercased().contains("successor_owns_team") {
            return .successorOwnsTeam(name: successorName(in: detail))
        }
        return .serverRejected(message)
    }

    /// The detail is the display name verbatim — confirmed against the live
    /// error: {"code":"23514","message":"successor_owns_team","details":"Test C"}.
    ///
    /// Deliberately not clever about it. An earlier version stripped a `key=`
    /// or `key:` prefix in case the server labelled the value, but display
    /// names are user-entered: "Sam: the keeper" would have been silently
    /// mangled to "the keeper". Showing a name that isn't theirs is worse than
    /// showing an odd one, and the format is known.
    static func successorName(in detail: String?) -> String? {
        guard let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // A name, not prose. Anything longer is a message we shouldn't be
        // pasting into the middle of a sentence of our own.
        guard text.count <= 60 else { return nil }
        return text
    }

    /// "team_limit_reached: 3" carries its limit; a bare token doesn't.
    private static func limit(in token: String) -> Int? {
        let digits = token.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
