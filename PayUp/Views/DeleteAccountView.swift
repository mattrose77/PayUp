import SwiftUI

/// The single confirmation step. What it says depends entirely on what's about
/// to be destroyed — see AccountDeletionCase.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: AccountDeletionFlow
    @FocusState private var focus: Field?

    private enum Field { case teamName, password }

    init(flow: AccountDeletionFlow) {
        _flow = State(initialValue: flow)
    }

    private var deletionCase: AccountDeletionCase { flow.deletionCase }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if let team = deletionCase.teamNameToConfirm {
                        typeToConfirm(team)
                    }

                    passwordField

                    if let message = flow.errorMessage {
                        Text(message)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(flow.isWorking ? "Deleting…" : deletionCase.confirmTitle) {
                        Task { await flow.delete() }
                    }
                    .buttonStyle(DangerButtonStyle())
                    .disabled(!flow.canDelete)

                    Button("Keep my account") { dismiss() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(flow.isWorking)
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textDim)
                        .disabled(flow.isWorking)
                }
            }
        }
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(flow.isWorking)
        .onAppear {
            focus = deletionCase.isDestructive ? .teamName : .password
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(deletionCase.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.beige)
                .fixedSize(horizontal: false, vertical: true)

            Text(deletionCase.message)
                .font(.system(size: 15))
                .foregroundStyle(deletionCase.isDestructive ? Theme.beige : Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(deletionCase.isDestructive ? Theme.danger : .clear, lineWidth: 1)
        )
    }

    private func typeToConfirm(_ team: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Type \(team) to confirm")
            TextField(
                "",
                text: $flow.typedTeamName,
                prompt: Text(team).foregroundStyle(Theme.textFaint)
            )
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.beige)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .focused($focus, equals: .teamName)
            .padding(16)
            .cardSurface()
            .onSubmit { focus = .password }
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Password")
            SecureField(
                "",
                text: $flow.password,
                prompt: Text("Your password").foregroundStyle(Theme.textFaint)
            )
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.beige)
            .textContentType(.password)
            .submitLabel(.done)
            .focused($focus, equals: .password)
            .padding(16)
            .cardSurface()
            Text("Confirming your password stops someone deleting your account from an unlocked phone.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The one red in the app. Reserved for the irreversible action itself.
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.bg : Theme.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                isEnabled ? Theme.danger : Theme.surfaceHi,
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
