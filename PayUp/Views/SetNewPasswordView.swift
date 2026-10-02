import SwiftUI

/// Where a reset link lands. The recovery session is already established, so
/// this only has to collect the new password; on success AuthService moves to
/// `.signedIn` and RootView takes over.
struct SetNewPasswordView: View {
    let auth: AuthService

    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case password, confirmation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 18) {
                    secure("New password", text: $password, field: .password)
                    secure("Confirm new password", text: $confirmation, field: .confirmation)

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button(busy ? "Saving…" : "Set new password", action: submit)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(busy || password.isEmpty || confirmation.isEmpty)

                HStack {
                    Spacer()
                    // The recovery session is live, so backing out has to end
                    // it — otherwise the next launch would land here again.
                    Button("Cancel and sign out") {
                        Task { await auth.signOut() }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .disabled(busy)
                    Spacer()
                }
            }
            .padding(20)
        }
        .keyboardDismissable(isFocused: focus != nil)
        .screenBackground()
        .onAppear { focus = .password }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New password")
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
        if case .recovering(_, let email) = auth.state, !email.isEmpty {
            return "Choose a new password for \(email)."
        }
        return "Choose a new password for your account."
    }

    private func secure(_ label: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: label)
            SecureField("", text: text, prompt: Text("••••••••").foregroundStyle(Theme.textFaint))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.beige)
                .textContentType(.newPassword)
                .focused($focus, equals: field)
                .submitLabel(field == .password ? .next : .done)
                .onSubmit {
                    if field == .password { focus = .confirmation } else { submit() }
                }
                .padding(16)
                .cardSurface()
        }
    }

    private func submit() {
        guard !busy else { return }
        if let problem = NewPasswordRules.problem(password: password, confirmation: confirmation) {
            error = problem
            return
        }
        error = nil
        busy = true
        Task {
            do {
                try await auth.setNewPassword(password)
            } catch {
                self.error = NewPasswordRules.message(for: error)
            }
            busy = false
        }
    }
}
