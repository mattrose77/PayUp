import SwiftUI

struct AuthView: View {
    enum Mode: Hashable { case signIn, signUp, reset, checkEmail }

    let auth: AuthService

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var emailError: String?
    @State private var passwordError: String?
    @State private var notice: String?
    @State private var busy = false
    /// Set when sign-in failed only because the address isn't confirmed, or
    /// after a sign-up that needs one. Drives the resend panel.
    @State private var unconfirmed: String?
    @State private var throttle = ResendThrottle()
    @State private var resendNotice: String?
    @State private var resending = false
    @State private var secondsLeft = 0
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if mode == .checkEmail {
                    confirmationPanel
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        field(
                            label: "Email",
                            text: $email,
                            prompt: "you@example.com",
                            error: emailError,
                            focusValue: .email
                        )
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)

                        if mode != .reset {
                            secureField
                        }
                    }

                    if let notice {
                        Text(notice)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Sign-in blocked only by an unconfirmed address: the fix
                    // is a resend, not a different password.
                    if unconfirmed != nil { resendPanel }

                    Button(primaryTitle, action: submit)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(busy || !isValid)
                }

                switcher
            }
            .padding(20)
        }
        .screenBackground()
        .animation(.snappy(duration: 0.25), value: mode)
        .animation(.snappy(duration: 0.25), value: unconfirmed)
        .task(id: throttle.lastSent) { await countDown() }
    }

    // MARK: - Confirmation

    /// Shown after sign-up instead of dumping the user back on a sign-in form
    /// that will refuse them until they've clicked the link.
    private var confirmationPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)

            Text("Confirm your email")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.beige)

            Text("Your account is created. We've sent a confirmation link to \(unconfirmed ?? email) — click it, then come back and sign in.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            Text(spamWarning)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            resendControls

            Button("Back to sign in") { switchTo(.signIn) }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(Theme.Radius.card)
    }

    /// The compact version, under the sign-in fields.
    private var resendPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spamWarning)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            resendControls
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var spamWarning: String {
        "It can take a minute to arrive. If you can't see it, check your spam or junk folder."
    }

    @ViewBuilder
    private var resendControls: some View {
        Button(resendTitle) { resend() }
            .buttonStyle(QuietButtonStyle())
            .disabled(resending || secondsLeft > 0)

        if let resendNotice {
            Text(resendNotice)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resendTitle: String {
        if resending { return "Sending…" }
        if secondsLeft > 0 { return "Resend in \(secondsLeft)s" }
        return "Resend confirmation email"
    }

    private func resend() {
        guard let address = unconfirmed ?? nonEmptyEmail, throttle.canSend() else { return }
        resending = true
        resendNotice = nil
        Task {
            do {
                try await auth.resendConfirmation(email: address)
                throttle.record()
                resendNotice = "Sent. Check your inbox for \(address), and your spam folder."
            } catch {
                resendNotice = nil
                emailError = AuthErrorText.forResend(error)
            }
            resending = false
        }
    }

    /// Ticks the button's label down so a disabled button explains itself.
    private func countDown() async {
        while throttle.secondsRemaining() > 0 {
            secondsLeft = throttle.secondsRemaining()
            try? await Task.sleep(for: .seconds(1))
        }
        secondsLeft = 0
    }

    private var nonEmptyEmail: String? {
        let address = email.trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PayUp")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.beige)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
    }

    private var subtitle: String {
        switch mode {
        case .signIn: return "Sign in to get to your team's fines."
        case .signUp: return "Create an account to start tracking fines."
        case .reset: return "We'll email you a link to set a new password."
        case .checkEmail: return "One more step before you're in."
        }
    }

    private var primaryTitle: String {
        if busy { return "Working…" }
        switch mode {
        case .signIn: return "Sign in"
        case .signUp: return "Create account"
        case .reset: return "Send reset link"
        case .checkEmail: return "Sign in"
        }
    }

    private func field(
        label: String,
        text: Binding<String>,
        prompt: String,
        error: String?,
        focusValue: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: label)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.textFaint))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.beige)
                .autocorrectionDisabled()
                .focused($focus, equals: focusValue)
                .padding(16)
                .cardSurface()
            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var secureField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Password")
            SecureField("", text: $password, prompt: Text("••••••••").foregroundStyle(Theme.textFaint))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.beige)
                .textContentType(mode == .signUp ? .newPassword : .password)
                .focused($focus, equals: .password)
                .padding(16)
                .cardSurface()
            if let passwordError {
                Text(passwordError)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mode == .signIn {
                Button("Forgotten your password?") { switchTo(.reset) }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private var switcher: some View {
        HStack(spacing: 6) {
            Spacer()
            switch mode {
            case .signIn:
                Text("No account yet?").foregroundStyle(Theme.textDim)
                Button("Create one") { switchTo(.signUp) }.foregroundStyle(Theme.accent)
            case .signUp:
                Text("Already have one?").foregroundStyle(Theme.textDim)
                Button("Sign in") { switchTo(.signIn) }.foregroundStyle(Theme.accent)
            case .reset:
                Button("Back to sign in") { switchTo(.signIn) }.foregroundStyle(Theme.accent)
            case .checkEmail:
                Text("Already confirmed?").foregroundStyle(Theme.textDim)
                Button("Sign in") { switchTo(.signIn) }.foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .font(.system(size: 14, weight: .medium))
    }

    // MARK: - Actions

    private var isValid: Bool {
        let hasEmail = email.contains("@") && email.count > 3
        return mode == .reset ? hasEmail : hasEmail && password.count >= 6
    }

    private func switchTo(_ next: Mode) {
        emailError = nil
        passwordError = nil
        notice = nil
        resendNotice = nil
        // The address stays pending across a hop back to sign-in, so the resend
        // option is still there when they come back to try again.
        if next == .signUp { unconfirmed = nil }
        mode = next
    }

    private func submit() {
        emailError = nil
        passwordError = nil
        notice = nil
        busy = true
        let address = email.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                switch mode {
                case .signIn, .checkEmail:
                    try await auth.signIn(email: address, password: password)
                    unconfirmed = nil
                case .signUp:
                    let usable = try await auth.signUp(email: address, password: password)
                    if !usable {
                        // Confirmation is on, so there's no session yet. Say so
                        // rather than bouncing them to a form that will refuse.
                        unconfirmed = address
                        password = ""
                        throttle.record()   // Supabase just sent one.
                        mode = .checkEmail
                    }
                case .reset:
                    try await auth.sendPasswordReset(email: address)
                    notice = "If that address has an account, a reset link is on its way."
                }
            } catch {
                // Errors land under the field they belong to, never in an alert.
                switch mode {
                case .signIn, .checkEmail:
                    let problem = AuthErrorText.signInProblem(error, email: address)
                    unconfirmed = problem.canResendConfirmation ? address : nil
                    if problem.canResendConfirmation {
                        emailError = problem.message
                        passwordError = nil
                    } else {
                        passwordError = problem.message
                    }
                case .signUp:
                    let text = AuthErrorText.forSignUp(error)
                    if text.lowercased().contains("email") {
                        emailError = text
                    } else {
                        passwordError = text
                    }
                case .reset:
                    emailError = error.localizedDescription
                }
            }
            busy = false
        }
    }
}
