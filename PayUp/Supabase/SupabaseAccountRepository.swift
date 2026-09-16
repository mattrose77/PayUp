import Foundation
import Supabase

struct SupabaseAccountRepository: AccountRepository {
    let client: SupabaseClient

    /// Signing in again is Supabase's re-auth: it proves the password and
    /// leaves a session recent enough for the delete to be accepted.
    func reauthenticate(email: String, password: String) async throws {
        guard !email.isEmpty else { throw AccountError.notSignedIn }
        do {
            _ = try await client.auth.signIn(email: email, password: password)
        } catch {
            throw Self.authError(from: error)
        }
    }

    func deleteAccount() async throws -> AccountDeletionOutcome {
        do {
            let raw: String = try await client.rpc("delete_account").execute().value
            // An outcome this build doesn't know about still means the account
            // is gone, so sign out rather than treating it as a failure.
            return AccountDeletionOutcome(rawValue: raw) ?? .accountOnly
        } catch {
            throw accountError(from: error)
        }
    }

    // MARK: - Errors

    /// A wrong password and a dead network both surface as a failed sign-in;
    /// only the first should read as "that password isn't right".
    static func authError(from error: Error) -> AccountError {
        let text = error.localizedDescription.lowercased()
        if text.contains("invalid login") || text.contains("invalid_credentials")
            || text.contains("invalid grant") {
            return .wrongPassword
        }
        return .serverRejected(error.localizedDescription)
    }

    /// The refusal token is in the message and the successor's display name is
    /// in the detail, so the two are kept apart rather than flattened.
    private func accountError(from error: Error) -> AccountError {
        guard let postgrest = error as? PostgrestError else {
            return .serverRejected(error.localizedDescription)
        }
        let message = [postgrest.message, postgrest.hint]
            .compactMap { $0 }
            .joined(separator: " ")
        return PostgresErrorMapper.accountError(from: message, detail: postgrest.details)
    }
}
