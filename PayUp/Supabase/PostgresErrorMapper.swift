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

        // 23503 is a foreign key violation. The only restrict-on-delete in the
        // schema is fines -> players, so this is always "they have history".
        if token.contains("23503")
            || token.contains("foreign key")
            || token.contains("violates foreign key constraint") {
            return .playerHasFines
        }

        return .serverRejected(message)
    }

    /// "team_limit_reached: 3" carries its limit; a bare token doesn't.
    private static func limit(in token: String) -> Int? {
        let digits = token.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
