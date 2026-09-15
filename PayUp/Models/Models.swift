import Foundation
import SwiftData

@Model
final class Player {
    var name: String = ""
    var createdAt: Date = Date()
    /// Position in the item-of-the-week rota.
    var rotaOrder: Int = 0
    /// Nil only for rows created before teams existed; the launch migration
    /// adopts them into the first team.
    var teamId: UUID?

    @Relationship(deleteRule: .cascade, inverse: \Fine.player)
    var fines: [Fine] = []

    @Relationship(inverse: \Match.itemOfTheWeekHolder)
    var itemWeeks: [Match] = []

    init(name: String, rotaOrder: Int = 0, teamId: UUID? = nil) {
        self.name = name
        self.createdAt = Date()
        self.rotaOrder = rotaOrder
        self.teamId = teamId
    }

    var initials: String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var totalFined: Int { fines.reduce(0) { $0 + $1.amountPence } }
    var totalPaid: Int { fines.filter(\.isPaid).reduce(0) { $0 + $1.amountPence } }
    var balance: Int { fines.filter { !$0.isPaid }.reduce(0) { $0 + $1.amountPence } }
    var isSettled: Bool { balance == 0 }
}

@Model
final class FineType {
    var name: String = ""
    /// Legacy pounds column, kept only so the pence migration can read it.
    var amount: Decimal = 0
    var amountPence: Int = 0
    var sortOrder: Int = 0
    /// Retired fines stay out of the chip row but keep their history intact.
    var isArchived: Bool = false
    var teamId: UUID?

    @Relationship(deleteRule: .nullify, inverse: \Fine.fineType)
    var fines: [Fine] = []

    init(name: String, amountPence: Int, sortOrder: Int = 0, teamId: UUID? = nil) {
        self.name = name
        self.amountPence = amountPence
        self.amount = Decimal(amountPence) / 100
        self.sortOrder = sortOrder
        self.teamId = teamId
    }
}

@Model
final class Match {
    var opponent: String = ""
    var date: Date = Date()
    /// What the item actually is this week — a cone, a hat, whatever the club
    /// has decided on.
    var itemOfTheWeek: String = ""
    /// Legacy: the squad-rota holder from the original build. Kept so the
    /// existing matchdays don't lose their data if the rota comes back.
    var itemOfTheWeekHolder: Player?
    /// Locks the tally against new fines. Payments stay open — settling up
    /// carries on for weeks after the fines themselves are final.
    var isComplete: Bool = false
    var completedAt: Date?
    var teamId: UUID?

    @Relationship(deleteRule: .cascade, inverse: \Fine.match)
    var fines: [Fine] = []

    init(opponent: String, date: Date, itemOfTheWeek: String = "", teamId: UUID? = nil) {
        self.opponent = opponent
        self.date = date
        self.itemOfTheWeek = itemOfTheWeek
        self.teamId = teamId
    }

    var total: Int { fines.reduce(0) { $0 + $1.amountPence } }
    var outstanding: Int { fines.filter { !$0.isPaid }.reduce(0) { $0 + $1.amountPence } }
}

@Model
final class Fine {
    var player: Player?
    var fineType: FineType?
    var match: Match?
    /// Legacy pounds column, kept only so the pence migration can read it.
    var amount: Decimal = 0
    /// Snapshotted at the moment of the fine so later edits to the fine type
    /// don't quietly rewrite what someone owes.
    var amountPence: Int = 0
    var label: String = ""
    var isPaid: Bool = false
    var paidAt: Date?
    var createdAt: Date = Date()
    var teamId: UUID?

    init(player: Player, fineType: FineType, match: Match) {
        self.player = player
        self.fineType = fineType
        self.match = match
        self.amountPence = fineType.amountPence
        self.amount = Decimal(fineType.amountPence) / 100
        self.label = fineType.name
        self.isPaid = false
        self.createdAt = Date()
        self.teamId = match.teamId
    }

    func setPaid(_ paid: Bool) {
        isPaid = paid
        paidAt = paid ? Date() : nil
    }
}
