import Foundation
import Supabase

// The reset email uses Supabase's PKCE flow: the link carries a one-time code,
// and the verifier needed to redeem it only exists in this app's storage on
// the device that asked for the reset. So the link has to come back here —
// no web page can finish it. `payup://reset-password` must be on the
// Redirect URLs allow list in the Supabase dashboard, or the email falls back
// to the Site URL.

/// What an incoming URL means for password recovery. Pure, so every link
/// format is testable without a network call.
enum PasswordResetLink: Equatable {
    /// A code to exchange for a recovery session.
    case code(String)
    /// Supabase redirected with an error instead of a code — usually an
    /// expired or already-used link.
    case failed(String)

    static let scheme = "payup"
    static let host = "reset-password"
    static let redirectURL = URL(string: "\(scheme)://\(host)")!

    /// Nil when the URL isn't a reset link at all, so callers can ignore it.
    static func parse(_ url: URL) -> PasswordResetLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // `payup://reset-password` puts it in the host; `payup:///reset-password`
        // (which some mail clients rewrite to) puts it in the path.
        let host = url.host()?.lowercased() ?? ""
        let path = url.path().lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host == Self.host || (host.isEmpty && path == Self.host) else { return nil }

        let params = parameters(of: url)

        // Errors win over a code: Supabase never sends both, and if it did the
        // code couldn't be trusted.
        if let description = params["error_description"] ?? params["error"] {
            return .failed(ResetLinkProblem.message(forRedirectError: description, code: params["error_code"]))
        }
        if let code = params["code"], !code.isEmpty {
            return .code(code)
        }
        return .failed(ResetLinkProblem.malformed)
    }

    /// Query and fragment both: PKCE errors arrive in the query, implicit-flow
    /// errors in the fragment, and Supabase has used both over time.
    private static func parameters(of url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var result: [String: String] = [:]
        for encoded in [components.percentEncodedFragment, components.percentEncodedQuery] {
            guard let encoded, !encoded.isEmpty else { continue }
            for pair in encoded.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first?.removingPercentEncoding, !name.isEmpty else { continue }
                let raw = parts.count > 1 ? parts[1] : ""
                result[name] = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
            }
        }
        return result
    }
}

/// What the user is told when a reset link can't be used. Every failure ends
/// in one of these, with a way to ask for a new link.
enum ResetLinkProblem {
    static let expired = "This reset link has expired or has already been used. Request a new one below."
    static let otherDevice = "This reset link has to be opened on the same phone you requested it from. "
        + "Request a new one below from this phone."
    static let malformed = "That reset link is incomplete. Request a new one below."
    static let offline = "Couldn't reach the server to check your reset link. "
        + "Check your connection, then tap the link in the email again."

    static func message(forRedirectError description: String, code: String?) -> String {
        let text = (description + " " + (code ?? "")).lowercased()
        if text.contains("expired") || text.contains("invalid") || text.contains("access_denied") {
            return expired
        }
        return description
    }

    /// For a failed code exchange.
    static func message(for error: Error) -> String {
        if error is URLError { return offline }
        let text = error.localizedDescription.lowercased()
        // No verifier stored: the reset was requested on another device, or
        // the app was reinstalled since.
        if text.contains("code verifier") || text.contains("code_verifier") {
            return otherDevice
        }
        // Anything else the server rejects — "invalid flow state",
        // flow_state_expired, a code already redeemed — means this link is
        // spent, and the fix is the same: ask for another.
        return expired
    }
}

/// Checks the set-new-password form before anything is sent.
enum NewPasswordRules {
    static let minimumLength = 6

    /// Nil when the pair is fine to submit.
    static func problem(password: String, confirmation: String) -> String? {
        if password.count < minimumLength {
            return "Passwords need to be at least \(minimumLength) characters."
        }
        if password != confirmation {
            return "Those passwords don't match."
        }
        return nil
    }

    static func message(for error: Error) -> String {
        if error is URLError {
            return "Couldn't reach the server. Check your connection and try again."
        }
        let text = error.localizedDescription.lowercased()
        if text.contains("same_password") || text.contains("different from the old") {
            return "That's your current password. Choose a new one."
        }
        if text.contains("weak_password") || (text.contains("password") && text.contains("least")) {
            return "That password is too weak. Try a longer one."
        }
        if text.contains("session") && (text.contains("missing") || text.contains("expired")) {
            return "Your reset session has expired. Request a new link."
        }
        return error.localizedDescription
    }
}

/// The two server calls recovery needs, behind a protocol so tests can drive
/// the state machine without a network.
protocol PasswordRecoveryBackend: Sendable {
    /// Redeems the link's code and establishes a session.
    func exchange(_ url: URL) async throws -> (userId: String, email: String)
    func updatePassword(_ password: String) async throws
}

struct SupabasePasswordRecoveryBackend: PasswordRecoveryBackend {
    let client: SupabaseClient

    func exchange(_ url: URL) async throws -> (userId: String, email: String) {
        let session = try await client.auth.session(from: url)
        return (UserID.normalise(session.user.id.uuidString), session.user.email ?? "")
    }

    func updatePassword(_ password: String) async throws {
        _ = try await client.auth.update(user: UserAttributes(password: password))
    }
}

/// Survives a relaunch, so killing the app on the set-password screen doesn't
/// drop the user into the app on the recovery session without a new password.
enum PendingRecovery {
    static let key = "payup.pendingPasswordRecoveryUserId"

    static func userId(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func set(_ userId: String?, _ defaults: UserDefaults = .standard) {
        if let userId {
            defaults.set(userId, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
