import Foundation
import SwiftData

enum SeedData {
    /// Amounts in pence.
    static let defaultFines: [(String, Int)] = [
        ("Gloves / hairband", 200),
        ("Lose a football", 200),
        ("No drink after game", 200),
        ("Late arrival", 200),
        ("Smoking or vaping near pitch", 200),
        ("Children in changing rooms", 200),
        ("Late payment", 200),
        ("Yellow card", 200),
        ("Incorrect attire", 200),
        ("Own goal", 200),
        ("New boots", 200),
        ("No item of the week", 300),
        ("Give away a penalty", 300),
        ("Dick of the day", 300),
        ("Miss a penalty", 300),
        ("Forget kit", 500),
        ("Sin bin", 500),
        ("Forget own item of the week", 600),
        ("Red card", 1000),
        ("Strop", 1000)
    ]

    /// Seeds a team's fine list. Runs when a team is created, not at launch,
    /// since fines belong to a team.
    static func seedFines(for teamId: UUID, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<FineType>())) ?? []
        guard !existing.contains(where: { $0.teamId == teamId }) else { return }
        for (index, entry) in defaultFines.enumerated() {
            context.insert(
                FineType(name: entry.0, amountPence: entry.1, sortOrder: index, teamId: teamId)
            )
        }
        try? context.save()
    }
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
        for fine in fines {
            if fine.isPaid { collected += fine.amountPence } else { outstanding += fine.amountPence }
        }
    }
}

/// The club this copy of the app belongs to. Mirrors the current team's name
/// so views that only need the label don't have to fetch the team.
enum Club {
    static let storageKey = "clubName"
    static let setupKey = "hasCompletedSetup"
    static let fallbackName = "Your Club"
    static let closingKey = "shareClosingLine"
    static let defaultClosing = "Late payment is a £2 fine. Get it in before Saturday."
}
