import Foundation
import Observation

/// Explicit row state rather than a scatter of booleans.
enum RowState {
    case pending
    case saved
    case failed(Error)

    var isPending: Bool { if case .pending = self { return true }; return false }
    var isSaved: Bool { if case .saved = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }

    var errorMessage: String? {
        if case .failed(let error) = self { return error.localizedDescription }
        return nil
    }
}

/// The spec's name for the player case; the machinery is shared with fine types.
typealias PlayerRowState = RowState

/// Rapid entry for list-building screens: type, return, keep typing.
///
/// Each submission gets a client-side id straight away so the row has an
/// identity before the server assigns one, and responses are matched back by
/// that id — never by name or index, because two players genuinely can share a
/// name and the list reorders as rows settle.
///
/// Saves run concurrently and may land in any order. Nothing is serialised
/// behind a lock; the array order is submission order and is never rearranged
/// by a response.
@MainActor
@Observable
final class RapidEntryQueue<Payload: Sendable> {
    struct Draft: Identifiable {
        let id: UUID
        var payload: Payload
        var state: RowState
    }

    private(set) var drafts: [Draft] = []

    /// Rows the list should show: anything still in flight or broken. Saved
    /// rows drop out because the real record has appeared in the main list.
    var visibleDrafts: [Draft] { drafts.filter { !$0.state.isSaved } }

    private let save: @Sendable (Payload) async throws -> Void

    init(save: @escaping @Sendable (Payload) async throws -> Void) {
        self.save = save
    }

    @discardableResult
    func submit(_ payload: Payload) -> UUID {
        // Settled rows are cleared as the next name is entered, so the list
        // stays short during a long squad entry.
        drafts.removeAll { $0.state.isSaved }

        let id = UUID()
        drafts.append(Draft(id: id, payload: payload, state: .pending))
        start(id)
        return id
    }

    func retry(_ id: UUID) {
        guard let index = index(of: id) else { return }
        drafts[index].state = .pending
        start(id)
    }

    /// Failed rows can be swiped away rather than retried.
    func discard(_ id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    func clearSaved() {
        drafts.removeAll { $0.state.isSaved }
    }

    private func start(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let payload = drafts[index].payload

        Task { [save] in
            do {
                try await save(payload)
                // Look the row up again by id — the array may have changed
                // while this was in flight.
                if let settled = self.index(of: id) {
                    self.drafts[settled].state = .saved
                }
            } catch {
                if let settled = self.index(of: id) {
                    self.drafts[settled].state = .failed(error)
                }
            }
        }
    }

    private func index(of id: UUID) -> Int? {
        drafts.firstIndex { $0.id == id }
    }
}

/// What the fines list submits: a name and what it costs.
struct FineTypeDraft: Sendable, Equatable {
    var name: String
    var amountPence: Int
}

enum EntryValidation {
    /// Rejected before any network call.
    static func cleanName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A warning, not a block — plenty of teams have two lads with the same name.
    static func duplicateWarning(for name: String, existing: [String]) -> String? {
        let match = existing.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        guard let match else { return nil }
        return "There's already a \(match) — added anyway."
    }
}
