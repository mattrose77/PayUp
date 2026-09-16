import Foundation
import Supabase
import Observation

// Email confirmation is ENABLED in the Supabase dashboard. Sign-up therefore
// returns no session: the user has to click the link first. Sign-in before
// that fails with `email_not_confirmed`, which is a normal state, not an
// error to bury — see SignInProblem.

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

    /// Needed to re-authenticate before destructive account actions.
    var email: String? {
        if case .signedIn(_, let email) = state { return email }
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

    /// Returns whether the account is usable straight away. With confirmation
    /// on it never is, but this doesn't assume the dashboard setting — if
    /// confirmation is turned off, a session comes back and we sign straight in.
    @discardableResult
    func signUp(email: String, password: String) async throws -> Bool {
        let response = try await client.auth.signUp(email: email, password: password)
        guard let session = response.session else { return false }
        state = .signedIn(
            userId: UserID.normalise(session.user.id.uuidString),
            email: session.user.email ?? email
        )
        return true
    }

    /// Asks Supabase to send the confirmation link again. Throttling is the
    /// caller's job — see ResendThrottle.
    func resendConfirmation(email: String) async throws {
        try await client.auth.resend(email: email, type: .signup)
    }

    func sendPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
    }

    func signOut() async {
        try? await client.auth.signOut()
        state = .signedOut
    }
}

/// Why a sign-in didn't work. Unconfirmed email is called out separately
/// because it's the one case with something the user can actually do about it.
enum SignInProblem: Equatable {
    case wrongCredentials
    case emailNotConfirmed(email: String)
    case other(String)

    var message: String {
        switch self {
        case .wrongCredentials:
            return "That email and password don't match."
        case .emailNotConfirmed(let email):
            return "Your account exists, but it hasn't been confirmed yet. "
                + "We sent a confirmation link to \(email) — click it, then sign in."
        case .other(let message):
            return message
        }
    }

    var canResendConfirmation: Bool {
        if case .emailNotConfirmed = self { return true }
        return false
    }
}

/// Turns Supabase's auth failures into something worth showing under a field.
enum AuthErrorText {
    /// Matches on the message body: Supabase sends `email_not_confirmed` as a
    /// code and "Email not confirmed" as a message depending on the endpoint.
    static func signInProblem(_ error: Error, email: String) -> SignInProblem {
        let text = error.localizedDescription.lowercased()
        if text.contains("email_not_confirmed") || text.contains("email not confirmed") {
            return .emailNotConfirmed(email: email)
        }
        if text.contains("invalid login") || text.contains("invalid_credentials")
            || text.contains("invalid grant") {
            return .wrongCredentials
        }
        return .other(error.localizedDescription)
    }

    static func forSignUp(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("already registered") || text.contains("already been registered")
            || text.contains("user_already_exists") {
            return "There's already an account with that email. Try signing in instead."
        }
        if text.contains("password") && text.contains("least") {
            return "Passwords need to be at least 6 characters."
        }
        return error.localizedDescription
    }

    static func forResend(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("rate") || text.contains("too many") || text.contains("seconds") {
            return "Supabase is rate-limiting confirmation emails. Wait a minute and try again."
        }
        return error.localizedDescription
    }
}

/// Stops the resend button being tapped five times in a row. Pure so the
/// interval is testable without waiting for it.
struct ResendThrottle {
    static let interval: TimeInterval = 60

    private(set) var lastSent: Date?

    func canSend(now: Date = Date()) -> Bool {
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= Self.interval
    }

    /// Whole seconds left before another send is allowed; 0 when it's allowed.
    func secondsRemaining(now: Date = Date()) -> Int {
        guard let lastSent else { return 0 }
        let left = Self.interval - now.timeIntervalSince(lastSent)
        return left > 0 ? Int(left.rounded(.up)) : 0
    }

    mutating func record(now: Date = Date()) { lastSent = now }
}
