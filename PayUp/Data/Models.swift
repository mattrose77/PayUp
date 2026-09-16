import Foundation

/// Plain value types matching the server rows. The decoder is configured for
/// snake_case, so property names mirror the columns exactly.
struct Player: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var teamId: UUID
    var name: String
    var active: Bool
    var userId: String?
    var createdAt: Date

    var initials: String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct FineType: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var teamId: UUID
    var name: String
    var amountPence: Int
    var active: Bool
    var sortOrder: Int
    var createdAt: Date
}

struct Match: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var teamId: UUID
    var opponent: String
    var playedOn: Date
    var isComplete: Bool
    var completedAt: Date?
    var itemOfTheWeek: String
    var createdAt: Date
}

struct Fine: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var teamId: UUID
    var matchId: UUID
    var playerId: UUID
    /// Null once its fine type is deleted — which is why display must never
    /// join back to fine_types.
    var fineTypeId: UUID?
    /// Snapshot of what the offence was called when it was issued.
    var description: String
    /// Snapshot of what it cost. Both are why history survives a deleted type.
    var amountPence: Int
    var paid: Bool
    var paidAt: Date?
    var createdBy: String?
    var createdAt: Date
}

// MARK: - Derived figures

extension Collection where Element == Fine {
    var totalPence: Int { reduce(0) { $0 + $1.amountPence } }
    var paidPence: Int { filter(\.paid).reduce(0) { $0 + $1.amountPence } }
    var outstandingPence: Int { filter { !$0.paid }.reduce(0) { $0 + $1.amountPence } }
}

/// Season-wide numbers used by the pot header and the shame board.
struct SeasonStats {
    var collected = 0
    var outstanding = 0
    var total: Int { collected + outstanding }
    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(collected) / Double(total)
    }

    init(fines: [Fine]) {
        collected = fines.paidPence
        outstanding = fines.outstandingPence
    }
}

/// The club this copy of the app belongs to. Mirrors the current team's name.
enum Club {
    static let storageKey = "clubName"
    static let fallbackName = "Your Club"
    static let closingKey = "shareClosingLine"
    static let defaultClosing = "Late payment is a £2 fine. Get it in before Saturday."
}
