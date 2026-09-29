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
        /// Signed in through a password reset link. The app stays closed
        /// until a new password is set — see SetNewPasswordView.
        case recovering(userId: String, email: String)
    }

    private(set) var state: State = .restoring

    /// Why the last reset link couldn't be used. Shown on the sign-in screen
    /// (or as an alert if someone is signed in) with a way to request another.
    var resetLinkProblem: String?

    /// A reset code is being exchanged. Covers the gap between tapping the
    /// link and the set-password screen appearing.
    private(set) var isRedeemingResetLink = false

    private let client: SupabaseClient
    private let recovery: PasswordRecoveryBackend
    private let defaults: UserDefaults

    init(
        client: SupabaseClient,
        recovery: PasswordRecoveryBackend? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.recovery = recovery ?? SupabasePasswordRecoveryBackend(client: client)
        self.defaults = defaults
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
    ///
    /// On a cold start from a reset link this races `handle(_:)`. Whichever
    /// finishes first, the reset link wins: restore only writes while the state
    /// is still `.restoring`, so it can't paper over a recovery session with a
    /// plain sign-in (which would skip the new-password screen).
    func restore() async {
        let restored: State
        do {
            let session = try await client.auth.session
            restored = restoredState(
                userId: UserID.normalise(session.user.id.uuidString),
                email: session.user.email ?? ""
            )
        } catch where error is URLError {
            // Offline with an expired access token: the refresh couldn't reach
            // the server, which isn't the same as the session being invalid.
            // Stay signed in on the stored session; the team screen then shows
            // a retry (and a sign-out) instead of bouncing to the sign-in form.
            if let stored = client.auth.currentSession {
                restored = restoredState(
                    userId: UserID.normalise(stored.user.id.uuidString),
                    email: stored.user.email ?? ""
                )
            } else {
                restored = .signedOut
            }
        } catch {
            restored = .signedOut
        }
        guard state == .restoring else { return }
        state = restored
    }

    /// A session left over from an unfinished reset goes back to the
    /// new-password screen, not into the app.
    func restoredState(userId: String, email: String) -> State {
        if let pending = PendingRecovery.userId(defaults), UserID.matches(pending, userId) {
            return .recovering(userId: userId, email: email)
        }
        return .signedIn(userId: userId, email: email)
    }

    // MARK: - Password reset

    /// Handles an incoming URL. Returns false if it isn't a reset link, so the
    /// caller can pass it on to something else.
    @discardableResult
    func handle(_ url: URL) async -> Bool {
        guard let link = PasswordResetLink.parse(url) else { return false }

        switch link {
        case .failed(let message):
            resetLinkProblem = message
        case .code:
            // A second tap while the first is still in flight would try to
            // spend the same code twice and report the second as "expired".
            guard !isRedeemingResetLink else { return true }
            isRedeemingResetLink = true
            resetLinkProblem = nil
            do {
                let user = try await recovery.exchange(url)
                // The link can be for a different account from the one signed
                // in here; its cached club name and display name mustn't carry over.
                if case .signedIn(let previous, _) = state, !UserID.matches(previous, user.userId) {
                    LocalState.clear(defaults)
                }
                PendingRecovery.set(user.userId, defaults)
                state = .recovering(userId: user.userId, email: user.email)
            } catch {
                // State is left alone: a signed-in user stays signed in, and on
                // a cold start restore() still resolves `.restoring` as usual.
                resetLinkProblem = ResetLinkProblem.message(for: error)
            }
            isRedeemingResetLink = false
        }
        return true
    }

    /// Sets the new password and lets the user into the app.
    func setNewPassword(_ password: String) async throws {
        guard case .recovering(let userId, let email) = state else { return }
        try await recovery.updatePassword(password)
        PendingRecovery.set(nil, defaults)
        state = .signedIn(userId: userId, email: email)
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
        try await client.auth.resetPasswordForEmail(email, redirectTo: PasswordResetLink.redirectURL)
    }

    func signOut() async {
        try? await client.auth.signOut()
        PendingRecovery.set(nil, defaults)
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
