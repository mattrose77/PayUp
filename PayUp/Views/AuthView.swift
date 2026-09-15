import SwiftUI

struct AuthView: View {
    enum Mode: Hashable { case signIn, signUp, reset }

    let auth: AuthService

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var emailError: String?
    @State private var passwordError: String?
    @State private var notice: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

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

                Button(primaryTitle, action: submit)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(busy || !isValid)

                switcher
            }
            .padding(20)
        }
        .screenBackground()
        .animation(.snappy(duration: 0.25), value: mode)
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
        }
    }

    private var primaryTitle: String {
        if busy { return "Working…" }
        switch mode {
        case .signIn: return "Sign in"
        case .signUp: return "Create account"
        case .reset: return "Send reset link"
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
                case .signIn:
                    try await auth.signIn(email: address, password: password)
                case .signUp:
                    try await auth.signUp(email: address, password: password)
                case .reset:
                    try await auth.sendPasswordReset(email: address)
                    notice = "If that address has an account, a reset link is on its way."
                }
            } catch {
                // Errors land under the field they belong to, never in an alert.
                switch mode {
                case .signIn:
                    passwordError = AuthErrorText.forSignIn(error)
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
