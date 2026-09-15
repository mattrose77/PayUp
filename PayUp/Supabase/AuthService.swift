import Foundation
import Supabase
import Observation

// NOTE: email confirmation is currently DISABLED in the Supabase dashboard so
// test accounts work immediately. It must be re-enabled before release —
// otherwise anyone can sign up with an address they don't control.

@MainActor
@Observable
final class AuthService {
    enum State: Equatable {
        /// Session restore hasn't finished. Callers must show a loading state
        /// rather than the sign-in screen, or an already-signed-in user sees a
        /// flash of sign-in on every launch.
        case restoring
        case signedOut
        case signedIn(userId: String, email: String)
    }

    private(set) var state: State = .restoring

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    var userId: String? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

    /// Reads any persisted session before the UI decides what to show.
    func restore() async {
        do {
            let session = try await client.auth.session
            state = .signedIn(
                userId: UserID.normalise(session.user.id.uuidString),
                email: session.user.email ?? ""
            )
        } catch {
            state = .signedOut
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await client.auth.signIn(email: email, password: password)
        state = .signedIn(userId: UserID.normalise(session.user.id.uuidString), email: session.user.email ?? email)
    }

    func signUp(email: String, password: String) async throws {
        let response = try await client.auth.signUp(email: email, password: password)
        // With confirmation disabled a session comes back immediately. Once it's
        // re-enabled this will be nil and the user must confirm by email first.
        if let session = response.session {
            state = .signedIn(
                userId: UserID.normalise(session.user.id.uuidString),
                email: session.user.email ?? email
            )
        } else {
            throw AuthMessage.confirmationRequired
        }
    }

    func sendPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
    }

    func signOut() async {
        try? await client.auth.signOut()
        state = .signedOut
    }
}

enum AuthMessage: LocalizedError {
    case confirmationRequired

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Check your email to confirm your account, then sign in."
        }
    }
}

/// Turns Supabase's auth failures into something worth showing under a field.
enum AuthErrorText {
    static func forSignIn(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("invalid login") || text.contains("invalid_credentials") {
            return "That email and password don't match."
        }
        if text.contains("email not confirmed") {
            return "Confirm your email address first, then sign in."
        }
        return error.localizedDescription
    }

    static func forSignUp(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("already registered") || text.contains("already been registered") {
            return "There's already an account with that email."
        }
        if text.contains("password") && text.contains("least") {
            return "Passwords need to be at least 6 characters."
        }
        return error.localizedDescription
    }
}
