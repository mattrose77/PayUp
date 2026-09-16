import Foundation
import SwiftData
import Observation

/// Everything the app keeps outside the database. A deleted account has to
/// leave nothing behind for the next launch to pick back up.
enum LocalState {
    static var keys: [String] {
        [Club.storageKey, Club.closingKey, CurrentUser.idKey, CurrentUser.nameKey]
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        for key in keys { defaults.removeObject(forKey: key) }
    }

    /// Teams and memberships are all SwiftData still holds; the rest lives in
    /// Postgres and goes with the account.
    @MainActor
    static func clearTeamStore(_ context: ModelContext) {
        try? context.delete(model: TeamMember.self)
        try? context.delete(model: Team.self)
        try? context.save()
    }
}

/// Drives the one confirmation step: validate, re-authenticate, delete, then
/// tear down the session. Separate from the view so "wrong password blocks it"
/// and "local state is cleared afterwards" are testable.
@MainActor
@Observable
final class AccountDeletionFlow: Identifiable {
    /// Presenting by item rather than a bool: the flow is built from the
    /// current team state at the moment the button is tapped.
    let id = UUID()

    enum Phase: Equatable {
        case editing
        case working
        case deleted(AccountDeletionOutcome)
        case failed(String)
    }

    let deletionCase: AccountDeletionCase
    var typedTeamName = ""
    var password = ""
    private(set) var phase: Phase = .editing

    private let account: AccountRepository
    private let email: String
    /// Sign out and wipe local state. Runs only after the server confirms.
    private let finish: @MainActor () async -> Void

    init(
        deletionCase: AccountDeletionCase,
        account: AccountRepository,
        email: String,
        finish: @escaping @MainActor () async -> Void
    ) {
        self.deletionCase = deletionCase
        self.account = account
        self.email = email
        self.finish = finish
    }

    var isWorking: Bool { phase == .working }

    var canDelete: Bool {
        guard !isWorking else { return false }
        return DeleteAccountForm.canDelete(
            deletionCase, typedTeamName: typedTeamName, password: password
        )
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func delete() async {
        guard canDelete else { return }
        phase = .working
        do {
            try await account.reauthenticate(email: email, password: password)
            let outcome = try await account.deleteAccount()
            password = ""
            // Order matters: the account is already gone server-side, so the
            // session must go before the UI can route anywhere else.
            await finish()
            phase = .deleted(outcome)
        } catch {
            password = ""
            phase = .failed(error.localizedDescription)
        }
    }
}
