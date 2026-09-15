import Foundation
import SwiftData

/// One-shot upgrades for stores created before teams and pence existed.
enum LaunchMigration {
    /// Amounts used to live in a Decimal of pounds. Copy them across once; the
    /// old column stays put so nothing is destroyed if this misfires.
    static func migrateMoneyToPence(_ context: ModelContext) {
        func pence(_ decimal: Decimal) -> Int {
            Int((NSDecimalNumber(decimal: decimal).doubleValue * 100).rounded())
        }

        let types = (try? context.fetch(FetchDescriptor<FineType>())) ?? []
        for type in types where type.amountPence == 0 && type.amount != 0 {
            type.amountPence = pence(type.amount)
        }

        let fines = (try? context.fetch(FetchDescriptor<Fine>())) ?? []
        for fine in fines where fine.amountPence == 0 && fine.amount != 0 {
            fine.amountPence = pence(fine.amount)
        }

        try? context.save()
    }

    /// Players, matches and fines still live in SwiftData; only the team itself
    /// is remote. Rows created before teams existed carry no teamId, so attach
    /// them to whichever team the account resolves to rather than stranding a
    /// season of fines.
    static func adoptOrphans(_ context: ModelContext, into teamId: UUID) {
        let players = (try? context.fetch(FetchDescriptor<Player>())) ?? []
        let matches = (try? context.fetch(FetchDescriptor<Match>())) ?? []
        let types = (try? context.fetch(FetchDescriptor<FineType>())) ?? []
        let fines = (try? context.fetch(FetchDescriptor<Fine>())) ?? []

        var changed = false
        for player in players where player.teamId == nil { player.teamId = teamId; changed = true }
        for match in matches where match.teamId == nil { match.teamId = teamId; changed = true }
        for type in types where type.teamId == nil { type.teamId = teamId; changed = true }
        for fine in fines where fine.teamId == nil { fine.teamId = teamId; changed = true }

        if changed { try? context.save() }
    }
}
