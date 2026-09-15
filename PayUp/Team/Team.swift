import Foundation
import SwiftData

/// Deliberately not a closed enum: unknown roles decode rather than crash, so
/// adding a role later needs no schema migration.
struct TeamRole: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let owner = TeamRole(rawValue: "owner")
    static let admin = TeamRole(rawValue: "admin")

    /// Roles that today have full access. Both do; the split is only about
    /// who can remove whom.
    var hasFullAccess: Bool { true }

    var label: String {
        switch self {
        case .owner: return "Owner"
        case .admin: return "Admin"
        default: return rawValue.capitalized
        }
    }
}

@Model
final class Team {
    var id: UUID = UUID()
    var name: String = ""
    var joinCode: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String, joinCode: String) {
        self.id = id
        self.name = name
        self.joinCode = joinCode
        self.createdAt = Date()
    }
}

@Model
final class TeamMember {
    var id: UUID = UUID()
    /// Scalar rather than a relationship: this is what a server row looks like,
    /// so sync doesn't have to translate.
    var teamId: UUID = UUID()
    var userId: String = ""
    var displayName: String = ""
    var roleRaw: String = TeamRole.admin.rawValue
    var joinedAt: Date = Date()

    var role: TeamRole {
        get { TeamRole(rawValue: roleRaw) }
        set { roleRaw = newValue.rawValue }
    }

    var initials: String {
        let parts = displayName.split(separator: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    init(teamId: UUID, userId: String, displayName: String, role: TeamRole) {
        self.id = UUID()
        self.teamId = teamId
        self.userId = userId
        self.displayName = displayName
        self.roleRaw = role.rawValue
        self.joinedAt = Date()
    }
}

enum JoinCode {
    /// No O/0/I/1 — these get read out in a changing room.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let length = 6

    static func generate() -> String {
        String((0..<length).map { _ in alphabet.randomElement() ?? "A" })
    }

    /// Accepts what someone actually types: spaces, lowercase, stray dashes.
    static func normalise(_ input: String) -> String {
        input.uppercased().filter { alphabet.contains($0) }
    }
}

/// Swift renders UUIDs uppercase; Postgres returns them lowercase. Comparing
/// the two raw is a silent mismatch that looks like "you're not a member of
/// your own team", so every user id is normalised through here.
enum UserID {
    static func normalise(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalise(lhs) == normalise(rhs)
    }
}

/// This device's identity. Stands in for a real auth user id until sign-in
/// exists; a Supabase user id drops straight into the same slot.
enum CurrentUser {
    private static let idKey = "localUserId"
    private static let nameKey = "localUserName"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: idKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: idKey)
        return fresh
    }

    static var displayName: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }
}
