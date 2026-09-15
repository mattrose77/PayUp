import Foundation

/// What an account is allowed to do. The single source of truth for limits —
/// nothing outside this layer should know what the numbers are.
struct Entitlements: Equatable, Sendable {
    var maxTeamsOwned: Int

    static let free = Entitlements(maxTeamsOwned: 1)
}

protocol EntitlementsProvider {
    var current: Entitlements { get }
}

/// Everyone is on the free tier until there's something to sell. When payments
/// land, a second provider reads the real tier and nothing else changes.
struct FreeEntitlementsProvider: EntitlementsProvider {
    var current: Entitlements { .free }
}
